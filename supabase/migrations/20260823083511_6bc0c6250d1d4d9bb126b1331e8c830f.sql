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
    raise exception '你没有查看这家门店成员的权限' using errcode = '42501';
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

create or replace function public.add_store_member(p_store_id uuid, p_user_id uuid, p_role text default 'clerk')
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
  if not exists (
    select 1 from public.store_members m
    where m.store_id = p_store_id and m.user_id = v_uid
      and m.status = 'active' and m.role in ('owner','admin')
  ) then
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

  if not exists (
    select 1 from public.store_members m
    where m.store_id = v_member.store_id and m.user_id = v_uid
      and m.status = 'active' and m.role in ('owner','admin')
  ) then
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

create or replace function public.bind_user_to_store(p_store_id uuid, p_confirm boolean default false)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_store public.stores%rowtype;
  v_current record;
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

  perform pg_advisory_xact_lock(hashtext('user_store_binding:' || v_uid::text));

  select b.store_id, s.name, s.address, s.phone, s.storefront_image_url
  into v_current
  from public.user_store_bindings b
  join public.stores s on s.id = b.store_id
  where b.user_id = v_uid and b.status = 'active'
  order by b.bound_at desc
  limit 1;

  if v_current.store_id is not null and v_current.store_id <> p_store_id then
    if coalesce(p_confirm, false) = false then
      return json_build_object(
        'bound', false,
        'already', true,
        'current', json_build_object(
          'store_id', v_current.store_id,
          'name', v_current.name,
          'address', v_current.address,
          'phone', v_current.phone,
          'storefront_image_url', v_current.storefront_image_url
        )
      );
    end if;
    update public.user_store_bindings
       set status = 'unbound', updated_at = now()
     where user_id = v_uid and status = 'active';
  end if;

  insert into public.user_store_bindings (user_id, store_id, status, bound_at, last_visit_at, created_at)
  values (v_uid, p_store_id, 'active', now(), now(), now())
  on conflict (user_id, store_id)
  do update set status = 'active', last_visit_at = now(), updated_at = now();

  return json_build_object(
    'bound', true,
    'store', json_build_object(
      'store_id', p_store_id,
      'name', v_store.name,
      'address', v_store.address,
      'phone', v_store.phone,
      'storefront_image_url', v_store.storefront_image_url
    )
  );
end;
$function$;

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
    select s.id, s.short_code, s.name, s.phone, s.status, s.root_manager_id,
           s.receipt_qr_url, s.payment_merchant_no, s.created_source,
           s.address, s.storefront_image_url, s.disabled_at, s.created_at,
           m.role as my_role
    from public.store_members m
    join public.stores s on s.id = m.store_id
    where m.user_id = v_uid and m.status = 'active'
  ) t;
  return json_build_object('items', coalesce(v_items, '[]'::json));
end;
$function$;

create or replace function public.update_store_profile(p_store_id uuid, p_name text, p_phone text, p_receipt_qr_url text, p_payment_merchant_no text, p_address text, p_storefront_image_url text)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_store public.stores%rowtype;
  v_is_manager boolean;
  v_name text := btrim(coalesce(p_name, ''));
  v_phone text := btrim(coalesce(p_phone, ''));
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select * into v_store from public.stores where id = p_store_id;
  if not found then
    raise exception '门店不存在' using errcode = '22023';
  end if;

  select exists (
    select 1 from public.store_members m
    where m.store_id = v_store.id and m.user_id = v_uid
      and m.status = 'active' and m.role in ('owner','admin')
  ) into v_is_manager;

  if not coalesce(v_is_manager, false)
     and not (
       v_uid = v_store.root_manager_id
       or public.is_enterprise_admin(v_uid)
     )
     and not public.is_admin(v_uid) then
    raise exception '你没有管理这家门店的权限' using errcode = '42501';
  end if;

  if v_name = '' or char_length(v_name) > 60 then
    raise exception '门店名称不能为空且不超过 60 字' using errcode = '22023';
  end if;
  if v_phone !~ '^1[3-9][0-9]{9}$' then
    raise exception '手机号格式不正确' using errcode = '22023';
  end if;
  if char_length(coalesce(p_receipt_qr_url, '')) > 2000 then
    raise exception '收款码链接过长' using errcode = '22023';
  end if;
  if char_length(coalesce(p_payment_merchant_no, '')) > 64 then
    raise exception '商户号登记信息过长' using errcode = '22023';
  end if;
  if char_length(coalesce(p_address, '')) > 200 then
    raise exception '门店地址最多 200 字' using errcode = '22023';
  end if;
  if char_length(coalesce(p_storefront_image_url, '')) > 2000 then
    raise exception '门头照片链接过长' using errcode = '22023';
  end if;

  update public.stores
     set name = v_name,
         phone = v_phone,
         receipt_qr_url = coalesce(p_receipt_qr_url, receipt_qr_url),
         payment_merchant_no = coalesce(p_payment_merchant_no, payment_merchant_no),
         address = coalesce(p_address, address),
         storefront_image_url = coalesce(p_storefront_image_url, storefront_image_url),
         updated_at = now()
   where id = v_store.id;

  return json_build_object('success', true);
end;
$function$;

grant execute on function public.list_store_members(uuid) to authenticated;
grant execute on function public.add_store_member(uuid, uuid, text) to authenticated;
grant execute on function public.update_store_member(uuid, text, text) to authenticated;
grant execute on function public.bind_user_to_store(uuid, boolean) to authenticated;
grant execute on function public.list_my_stores() to authenticated;
grant execute on function public.update_store_profile(uuid, text, text, text, text, text, text) to authenticated;