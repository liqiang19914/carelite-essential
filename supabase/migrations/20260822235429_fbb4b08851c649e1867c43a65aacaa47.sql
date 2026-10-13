create or replace function public.list_my_stores()
returns json
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_items json;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select json_agg(t order by t.created_at desc) into v_items
  from (
    select s.id, s.short_code, s.name, s.status, s.root_manager_id,
           s.receipt_qr_url, s.address, s.storefront_image_url, s.created_at,
           m.role as my_role
    from public.store_members m
    join public.stores s on s.id = m.store_id
    where m.user_id = v_uid and m.status = 'active'
  ) t;
  return json_build_object('items', coalesce(v_items, '[]'::json));
end;
$function$;

create or replace function public.list_my_store_orders(p_store_id uuid, p_status text default 'active', p_limit integer default 20, p_offset integer default 0)
returns json
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_store public.stores%rowtype;
  v_items json;
  v_total integer;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select * into v_store from public.stores where id = p_store_id;
  if not found or not exists (
    select 1 from public.store_members m
    where m.store_id = v_store.id and m.user_id = v_uid and m.status = 'active'
  ) then
    raise exception '你没有查看这家门店订单的权限' using errcode = '42501';
  end if;

  select count(*) into v_total
  from public.orders o
  where o.store_id = v_store.id
    and o.payment_channel = 'offline_store'
    and (
      (p_status = 'active' and o.offline_status in ('awaiting_payment','awaiting_verification'))
      or (p_status = 'verified' and o.offline_status = 'verified')
      or (p_status = 'cancelled' and o.offline_status = 'cancelled')
      or (p_status = 'all')
    );

  select json_agg(t order by t.created_at desc) into v_items
  from (
    select o.id, o.out_trade_no, o.product_title_snapshot, o.cover_image_snapshot,
           o.unit_price_cents, o.quantity, o.total_amount_cents,
           o.contact_name, o.contact_phone, o.remark,
           o.offline_status, o.offline_claimed_at, o.verified_at, o.created_at,
           o.requires_shipping_snapshot, o.user_id
    from public.orders o
    where o.store_id = v_store.id
      and o.payment_channel = 'offline_store'
      and (
        (p_status = 'active' and o.offline_status in ('awaiting_payment','awaiting_verification'))
        or (p_status = 'verified' and o.offline_status = 'verified')
        or (p_status = 'cancelled' and o.offline_status = 'cancelled')
        or (p_status = 'all')
      )
    order by o.created_at desc
    limit greatest(least(p_limit, 100), 1)
    offset greatest(p_offset, 0)
  ) t;

  return json_build_object('items', coalesce(v_items, '[]'::json), 'total', v_total);
end;
$function$;

create or replace function public.verify_offline_store_order(p_order_id uuid)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_order public.orders%rowtype;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception '订单不存在' using errcode = '22023';
  end if;
  if v_order.payment_channel <> 'offline_store' then
    raise exception '这不是门店线下订单' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.store_members m
    join public.stores s on s.id = m.store_id
    where s.id = v_order.store_id and m.user_id = v_uid and m.status = 'active'
  ) then
    raise exception '只有这家门店的成员才能核销' using errcode = '42501';
  end if;

  if v_order.offline_status = 'verified' then
    return json_build_object('success', true, 'already', true);
  end if;
  if v_order.offline_status = 'cancelled' then
    raise exception '订单已取消，无法核销' using errcode = '22023';
  end if;
  if v_order.offline_status is distinct from 'awaiting_verification' then
    raise exception '客户还没有确认到店付款，暂时不能核销' using errcode = '22023';
  end if;

  update public.orders
     set offline_status = 'verified',
         status = 'paid',
         payment_method = 'offline',
         paid_at = now(),
         completed_at = now(),
         verified_by = v_uid,
         verified_at = now(),
         updated_at = now()
   where id = v_order.id;

  return json_build_object('success', true);
end;
$function$;

create or replace function public.cancel_offline_store_order(p_order_id uuid)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_root uuid;
  v_order public.orders%rowtype;
  v_is_member boolean;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception '订单不存在' using errcode = '22023';
  end if;
  if v_order.payment_channel <> 'offline_store' then
    raise exception '这不是门店线下订单' using errcode = '22023';
  end if;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  select exists (
    select 1 from public.store_members m
    where m.store_id = v_order.store_id and m.user_id = v_uid and m.status = 'active'
  ) into v_is_member;

  if v_order.user_id is distinct from v_uid
     and not coalesce(v_is_member, false)
     and v_root is distinct from v_order.shop_manager_id_snapshot then
    raise exception '你没有操作这个订单的权限' using errcode = '42501';
  end if;

  if v_order.offline_status = 'verified' then
    raise exception '订单已经核销，无法取消，请走退货流程' using errcode = '22023';
  end if;
  if v_order.offline_status = 'cancelled' then
    return json_build_object('success', true, 'already', true);
  end if;

  update public.orders
     set offline_status = 'cancelled',
         status = 'cancelled',
         cancelled_at = now(),
         updated_at = now()
   where id = v_order.id and offline_status in ('awaiting_payment','awaiting_verification');

  if v_order.stock_decremented then
    update public.product_skus
       set stock = stock + v_order.quantity, updated_at = now()
     where id = v_order.sku_id;
    update public.orders
       set stock_decremented = false
     where id = v_order.id and offline_status = 'cancelled';
  end if;

  return json_build_object('success', true);
end;
$function$;