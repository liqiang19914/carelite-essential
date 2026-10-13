-- 审查修复 1：企业门店列表仅企业老板/管理员可读，普通员工不再能看到全企业门店电话与收款码
create or replace function public.list_enterprise_stores()
returns json
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_root uuid;
  v_items json;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  if v_root is null or not public.is_enterprise_admin(v_uid) then
    raise exception '只有企业老板或管理员才能管理门店' using errcode = '42501';
  end if;

  select json_agg(t order by t.created_at desc) into v_items
  from (
    select s.id, s.short_code, s.name, s.phone, s.status,
           s.receipt_qr_url, s.payment_merchant_no, s.created_source,
           s.address, s.storefront_image_url,
           s.disabled_at, s.created_at,
           (s.operator_user_id is null) as awaiting_claim,
           op.nickname as operator_nickname,
           (select count(*) from public.user_store_bindings b
             where b.store_id = s.id and b.status = 'active')::integer as customer_count
    from public.stores s
    left join public.profiles op on op.id = s.operator_user_id
    where s.root_manager_id = v_root
  ) t;
  return json_build_object('items', coalesce(v_items, '[]'::json));
end;
$function$;

grant execute on function public.list_enterprise_stores() to authenticated;

-- 审查修复 2：企业管理员走 _can_admin_store 时角色按 admin 处理，不再被提升为店主（保持「管理员不能移除管理员」约束）
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
      v_caller_role := 'admin';
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

-- 审查修复 3：停业门店无论走成员通道还是企业管理员通道都不能核销
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

  if not exists (
    select 1 from public.stores s
    where s.id = v_order.store_id and s.status = 'active'
  ) then
    raise exception '这家门店已停业，不能核销' using errcode = '22023';
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

  if not exists (
    select 1 from public.stores s
    where s.id = v_order.store_id and s.status = 'active'
  ) then
    raise exception '这家门店已停业，不能核销' using errcode = '22023';
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