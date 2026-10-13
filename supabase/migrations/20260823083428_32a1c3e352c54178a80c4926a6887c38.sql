create or replace function public.cancel_offline_store_order(p_order_id uuid)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_order public.orders%rowtype;
  v_can_cancel boolean;
  v_updated integer;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;

  select * into v_order from public.orders
  where id = p_order_id
  for update;
  if not found then
    raise exception '订单不存在' using errcode = '22023';
  end if;
  if v_order.payment_channel <> 'offline_store' then
    raise exception '这不是门店线下订单' using errcode = '22023';
  end if;

  select (
    v_order.user_id = v_uid
    or exists (
      select 1 from public.store_members m
      where m.store_id = v_order.store_id and m.user_id = v_uid
        and m.status = 'active' and m.role in ('owner','admin')
    )
    or (
      public.get_enterprise_root_manager_id(v_uid)
        = v_order.shop_manager_id_snapshot
      and public.is_enterprise_admin(v_uid)
    )
  ) into v_can_cancel;

  if not coalesce(v_can_cancel, false) then
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
   where id = v_order.id
     and offline_status in ('awaiting_payment','awaiting_verification');

  get diagnostics v_updated = row_count;

  if v_order.stock_decremented and v_updated > 0 then
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
      and s.status = 'active'
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

create or replace function public.verify_offline_store_order_by_code(p_code text)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_no text := public.parse_store_order_code(btrim(coalesce(p_code, '')));
  v_order public.orders%rowtype;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  if v_no = '' then
    raise exception '核销码不能为空' using errcode = '22023';
  end if;

  select * into v_order from public.orders
  where out_trade_no = v_no and payment_channel = 'offline_store'
  for update;
  if not found then
    raise exception '没有找到这张核销码对应的订单' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.store_members m
    join public.stores s on s.id = m.store_id
    where s.id = v_order.store_id and m.user_id = v_uid and m.status = 'active'
      and s.status = 'active'
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

create or replace function public.preview_offline_store_order_by_code(p_code text)
returns json
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_no text := public.parse_store_order_code(btrim(coalesce(p_code, '')));
  v_order public.orders%rowtype;
  v_is_member boolean;
  v_store_name text;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  if v_no = '' then
    raise exception '核销码不能为空' using errcode = '22023';
  end if;

  select * into v_order from public.orders
  where out_trade_no = v_no and payment_channel = 'offline_store';
  if not found then
    raise exception '没有找到这张核销码对应的订单' using errcode = '22023';
  end if;

  select exists (
    select 1 from public.store_members m
    where m.store_id = v_order.store_id and m.user_id = v_uid and m.status = 'active'
  ) into v_is_member;
  if not coalesce(v_is_member, false) then
    raise exception '只有这家门店的成员才能核销' using errcode = '42501';
  end if;

  select name into v_store_name from public.stores where id = v_order.store_id;

  return json_build_object(
    'order_id', v_order.id,
    'out_trade_no', v_order.out_trade_no,
    'product_title', v_order.product_title_snapshot,
    'cover_image_url', v_order.cover_image_snapshot,
    'quantity', v_order.quantity,
    'total_amount_cents', v_order.total_amount_cents,
    'contact_name', v_order.contact_name,
    'contact_phone', case
      when public.is_admin(v_uid) then v_order.contact_phone
      when v_order.contact_phone ~ '^1[0-9]{10}$' then left(v_order.contact_phone, 3) || '****' || right(v_order.contact_phone, 4)
      else v_order.contact_phone
    end,
    'remark', v_order.remark,
    'offline_status', v_order.offline_status,
    'store_name', coalesce(v_store_name, ''),
    'created_at', v_order.created_at
  );
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
  v_role text;
  v_items json;
  v_total integer;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select m.role into v_role
  from public.store_members m
  where m.store_id = p_store_id and m.user_id = v_uid and m.status = 'active';
  if v_role is null then
    raise exception '你没有查看这家门店订单的权限' using errcode = '42501';
  end if;

  select count(*) into v_total
  from public.orders o
  where o.store_id = p_store_id
    and o.payment_channel = 'offline_store'
    and (
      (p_status = 'active' and o.offline_status in ('awaiting_payment','awaiting_verification'))
      or (p_status = 'verified' and o.offline_status = 'verified'
          and (v_role <> 'clerk' or o.verified_by = v_uid))
      or (p_status = 'cancelled' and o.offline_status = 'cancelled'
          and (v_role <> 'clerk' or o.user_id = v_uid))
      or (p_status = 'all' and (v_role <> 'clerk' or o.verified_by = v_uid or o.user_id = v_uid))
    );

  select json_agg(t order by t.created_at desc) into v_items
  from (
    select o.id, o.out_trade_no, o.product_title_snapshot, o.cover_image_snapshot,
           o.unit_price_cents, o.quantity, o.total_amount_cents,
           o.contact_name,
           case
             when public.is_admin(v_uid) then o.contact_phone
             when o.contact_phone ~ '^1[0-9]{10}$' then left(o.contact_phone, 3) || '****' || right(o.contact_phone, 4)
             else o.contact_phone
           end as contact_phone,
           o.remark,
           o.offline_status, o.offline_claimed_at, o.verified_at, o.created_at,
           o.requires_shipping_snapshot, o.user_id,
           vp.nickname as verified_by_nickname
    from public.orders o
    left join public.profiles vp on vp.id = o.verified_by
    where o.store_id = p_store_id
      and o.payment_channel = 'offline_store'
      and (
        (p_status = 'active' and o.offline_status in ('awaiting_payment','awaiting_verification'))
        or (p_status = 'verified' and o.offline_status = 'verified'
            and (v_role <> 'clerk' or o.verified_by = v_uid))
        or (p_status = 'cancelled' and o.offline_status = 'cancelled'
            and (v_role <> 'clerk' or o.user_id = v_uid))
        or (p_status = 'all' and (v_role <> 'clerk' or o.verified_by = v_uid or o.user_id = v_uid))
      )
    order by o.created_at desc
    limit greatest(least(p_limit, 100), 1)
    offset greatest(p_offset, 0)
  ) t;

  return json_build_object('items', coalesce(v_items, '[]'::json), 'total', v_total);
end;
$function$;

grant execute on function public.cancel_offline_store_order(uuid) to authenticated;
grant execute on function public.verify_offline_store_order(uuid) to authenticated;
grant execute on function public.verify_offline_store_order_by_code(text) to authenticated;
grant execute on function public.preview_offline_store_order_by_code(text) to authenticated;
grant execute on function public.list_my_store_orders(uuid, text, integer, integer) to authenticated;