create or replace function public.parse_store_order_code(p_code text)
returns text
language sql
immutable
as $function$
  select case
    when p_code like 'kaitong-store-order:v1:%' then substring(p_code from 24)
    else p_code
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
    'contact_phone', v_order.contact_phone,
    'remark', v_order.remark,
    'offline_status', v_order.offline_status,
    'store_name', coalesce(v_store_name, ''),
    'created_at', v_order.created_at
  );
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
    where m.store_id = v_order.store_id and m.user_id = v_uid and m.status = 'active'
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

create or replace function public.join_store_as_clerk(p_store_id uuid)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_store public.stores%rowtype;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select * into v_store from public.stores where id = p_store_id;
  if not found then
    raise exception '门店不存在' using errcode = '22023';
  end if;
  if v_store.status <> 'active' then
    raise exception '这家门店已暂停营业' using errcode = '22023';
  end if;

  insert into public.store_members (store_id, user_id, role, status, created_at, updated_at)
  values (p_store_id, v_uid, 'clerk', 'active', now(), now())
  on conflict (store_id, user_id)
  do update set status = 'active', updated_at = now()
  where public.store_members.role = 'clerk';

  return json_build_object('success', true, 'store_id', p_store_id, 'store_name', v_store.name);
end;
$function$;

grant execute on function public.parse_store_order_code(text) to authenticated;
grant execute on function public.preview_offline_store_order_by_code(text) to authenticated;
grant execute on function public.verify_offline_store_order_by_code(text) to authenticated;
grant execute on function public.join_store_as_clerk(uuid) to authenticated;