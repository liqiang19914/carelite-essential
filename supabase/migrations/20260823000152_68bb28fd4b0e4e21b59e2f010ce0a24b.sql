create or replace function public.get_store_sales_overview(p_store_id uuid)
returns json
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_customers integer;
  v_verified_count integer;
  v_verified_amount bigint;
  v_active_count integer;
  v_top json;
  v_by_member json;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select m.role into v_role
  from public.store_members m
  where m.store_id = p_store_id and m.user_id = v_uid and m.status = 'active';
  if v_role is null then
    raise exception '你不是这家门店的成员' using errcode = '42501';
  end if;

  select count(*) into v_customers
  from public.user_store_bindings b
  where b.store_id = p_store_id and b.status = 'active';

  if v_role = 'clerk' then
    select count(*) into v_verified_count
    from public.orders o
    where o.store_id = p_store_id and o.payment_channel = 'offline_store'
      and o.offline_status = 'verified' and o.verified_by = v_uid;
    select coalesce(sum(o.total_amount_cents), 0) into v_verified_amount
    from public.orders o
    where o.store_id = p_store_id and o.payment_channel = 'offline_store'
      and o.offline_status = 'verified' and o.verified_by = v_uid;
  else
    select count(*) into v_verified_count
    from public.orders o
    where o.store_id = p_store_id and o.payment_channel = 'offline_store'
      and o.offline_status = 'verified';
    select coalesce(sum(o.total_amount_cents), 0) into v_verified_amount
    from public.orders o
    where o.store_id = p_store_id and o.payment_channel = 'offline_store'
      and o.offline_status = 'verified';
  end if;

  select count(*) into v_active_count
  from public.orders o
  where o.store_id = p_store_id and o.payment_channel = 'offline_store'
    and o.offline_status in ('awaiting_payment','awaiting_verification');

  select coalesce(json_agg(t), '[]'::json) into v_top
  from (
    select o.product_title_snapshot as title, o.cover_image_snapshot as cover_image_url,
           count(*) as orders, coalesce(sum(o.quantity), 0) as quantity,
           coalesce(sum(o.total_amount_cents), 0) as amount_cents
    from public.orders o
    where o.store_id = p_store_id and o.payment_channel = 'offline_store'
      and o.offline_status = 'verified'
      and (v_role <> 'clerk' or o.verified_by = v_uid)
    group by o.product_title_snapshot, o.cover_image_snapshot
    order by amount_cents desc
    limit 5
  ) t;

  select coalesce(json_agg(t order by t.verified_count desc), '[]'::json) into v_by_member
  from (
    select m.user_id,
           coalesce(p.nickname, '') as nickname,
           m.role,
           count(o.id) as verified_count,
           coalesce(sum(o.total_amount_cents), 0) as amount_cents
    from public.store_members m
    left join public.profiles p on p.id = m.user_id
    left join public.orders o on o.store_id = m.store_id
      and o.payment_channel = 'offline_store'
      and o.offline_status = 'verified'
      and o.verified_by = m.user_id
    where m.store_id = p_store_id and m.status = 'active'
      and (v_role <> 'clerk' or m.user_id = v_uid)
    group by m.user_id, p.nickname, m.role
  ) t;

  return json_build_object(
    'my_role', v_role,
    'customer_count', v_customers,
    'verified_count', v_verified_count,
    'verified_amount_cents', v_verified_amount,
    'active_orders', v_active_count,
    'top_products', v_top,
    'by_member', v_by_member
  );
end;
$function$;

grant execute on function public.get_store_sales_overview(uuid) to authenticated;

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
           o.requires_shipping_snapshot, o.user_id,
           vp.nickname as verified_by_nickname
    from public.orders o
    left join public.profiles vp on vp.id = o.verified_by
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

grant execute on function public.list_my_store_orders(uuid, text, integer, integer) to authenticated;