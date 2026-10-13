-- 270 商户电脑端一键进入门店工作台：企业老板/管理员用自己的账号操作本企业门店
-- 新增辅助闸门：门店成员(owner/admin) 或 门店所属企业的管理员 可管理该门店
create or replace function public._can_admin_store(p_store_id uuid)
returns boolean
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_root uuid;
begin
  if v_uid is null then
    return false;
  end if;
  if exists (
    select 1 from public.store_members m
    where m.store_id = p_store_id and m.user_id = v_uid
      and m.status = 'active' and m.role in ('owner','admin')
  ) then
    return true;
  end if;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  return v_root is not null
    and public.is_enterprise_admin(v_uid)
    and exists (
      select 1 from public.stores s
      where s.id = p_store_id and s.root_manager_id = v_root
    );
end;
$function$;

revoke all on function public._can_admin_store(uuid) from public, anon, authenticated;

-- 销售概览：企业管理员以 admin 角色查看
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
    if public._can_admin_store(p_store_id) then
      v_role := 'admin';
    else
      raise exception '你不是这家门店的成员' using errcode = '42501';
    end if;
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

-- 门店订单列表：企业管理员以 admin 角色查看
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
    if public._can_admin_store(p_store_id) then
      v_role := 'admin';
    else
      raise exception '你没有查看这家门店订单的权限' using errcode = '42501';
    end if;
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

grant execute on function public.list_my_store_orders(uuid, text, integer, integer) to authenticated;

-- 门店成员列表：企业管理员可查看
create or replace function public.list_store_members(p_store_id uuid)
returns json
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_items json;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select m.role into v_role
  from public.store_members m
  where m.store_id = p_store_id and m.user_id = v_uid and m.status = 'active';
  if v_role is null then
    if public._can_admin_store(p_store_id) then
      v_role := 'admin';
    else
      raise exception '你没有查看这家门店成员的权限' using errcode = '42501';
    end if;
  end if;
  if v_role = 'clerk' then
    raise exception '只有店主或管理员才能查看门店成员' using errcode = '42501';
  end if;

  select json_agg(t order by t.created_at asc) into v_items
  from (
    select m.id, m.user_id, m.role, m.status, m.created_at,
           p.nickname, p.avatar_url, p.phone
    from public.store_members m
    join public.profiles p on p.id = m.user_id
    where m.store_id = p_store_id
  ) t;
  return json_build_object('items', coalesce(v_items, '[]'::json));
end;
$function$;

grant execute on function public.list_store_members(uuid) to authenticated;

-- 添加成员：企业管理员可代门店添加
create or replace function public.add_store_member(p_store_id uuid, p_user_id uuid, p_role text default 'clerk'::text)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_role text := coalesce(p_role, 'clerk');
  v_target_role text;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  if v_role not in ('admin','clerk') then
    raise exception '成员角色不正确' using errcode = '22023';
  end if;
  if not public._can_admin_store(p_store_id) then
    raise exception '只有店主或管理员才能添加成员' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception '这个用户不存在' using errcode = '22023';
  end if;
  if p_user_id = v_uid then
    raise exception '不能把自己添加成成员' using errcode = '22023';
  end if;

  select m.role into v_target_role
  from public.store_members m
  where m.store_id = p_store_id and m.user_id = p_user_id
  for update;
  if v_target_role = 'owner' then
    raise exception '不能变更店主的角色' using errcode = '42501';
  end if;

  insert into public.store_members (store_id, user_id, role, status, invited_by, created_at, updated_at)
  values (p_store_id, p_user_id, v_role, 'active', v_uid, now(), now())
  on conflict (store_id, user_id)
  do update set role = excluded.role, status = 'active', updated_at = now();

  return json_build_object('success', true);
end;
$function$;

grant execute on function public.add_store_member(uuid, uuid, text) to authenticated;

-- 修改成员：企业管理员可代门店调整
create or replace function public.update_store_member(p_member_id uuid, p_role text, p_status text)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_member public.store_members%rowtype;
  v_role text := coalesce(p_role, '');
  v_status text := coalesce(p_status, '');
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select * into v_member from public.store_members where id = p_member_id;
  if not found then
    raise exception '成员不存在' using errcode = '22023';
  end if;
  if v_member.role = 'owner' then
    raise exception '店主的角色和状态不能修改' using errcode = '42501';
  end if;
  if v_member.user_id = v_uid then
    raise exception '不能修改自己的角色和状态' using errcode = '22023';
  end if;

  if not public._can_admin_store(v_member.store_id) then
    raise exception '只有店主或管理员才能管理成员' using errcode = '42501';
  end if;

  if v_role = '' then
    v_role := v_member.role;
  end if;
  if v_status = '' then
    v_status := v_member.status;
  end if;
  if v_role not in ('admin','clerk') or v_status not in ('active','disabled') then
    raise exception '角色或状态不正确' using errcode = '22023';
  end if;

  update public.store_members
     set role = v_role, status = v_status, updated_at = now()
   where id = v_member.id;

  return json_build_object('success', true);
end;
$function$;

grant execute on function public.update_store_member(uuid, text, text) to authenticated;

-- 移除成员：企业管理员可代门店移除
create or replace function public.remove_store_member(p_member_id uuid)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_member public.store_members%rowtype;
  v_caller_role text;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select * into v_member from public.store_members where id = p_member_id;
  if not found then
    raise exception '成员不存在' using errcode = '22023';
  end if;
  if v_member.role = 'owner' then
    raise exception '店主不能被移除' using errcode = '42501';
  end if;

  select m.role into v_caller_role
  from public.store_members m
  where m.store_id = v_member.store_id and m.user_id = v_uid and m.status = 'active';
  if v_caller_role is null then
    if public._can_admin_store(v_member.store_id) then
      v_caller_role := 'owner';
    else
      raise exception '你不是这家门店的成员' using errcode = '42501';
    end if;
  end if;
  if v_caller_role = 'clerk' then
    raise exception '店员不能移除成员' using errcode = '42501';
  end if;
  if v_caller_role = 'admin' and v_member.role = 'admin' then
    raise exception '管理员不能移除管理员' using errcode = '42501';
  end if;

  delete from public.store_members where id = v_member.id;

  return json_build_object('success', true);
end;
$function$;

grant execute on function public.remove_store_member(uuid) to authenticated;

-- 核销码预览：企业管理员可代门店核销
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
  if not coalesce(v_is_member, false)
     and not public._can_admin_store(v_order.store_id) then
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

grant execute on function public.preview_offline_store_order_by_code(text) to authenticated;

-- 按订单核销：企业管理员可代门店核销
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
  ) and not public._can_admin_store(v_order.store_id) then
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

grant execute on function public.verify_offline_store_order(uuid) to authenticated;

-- 按码核销：企业管理员可代门店核销
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
  ) and not public._can_admin_store(v_order.store_id) then
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

grant execute on function public.verify_offline_store_order_by_code(text) to authenticated;