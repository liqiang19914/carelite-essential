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

create or replace function public.list_my_bound_stores()
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
  select json_agg(t order by t.bound_at desc) into v_items
  from (
    select s.id as store_id, s.name, s.address, s.phone,
           s.storefront_image_url, s.short_code, s.receipt_qr_url,
           m.business_name as brand_name,
           b.bound_at, b.last_visit_at
    from public.user_store_bindings b
    join public.stores s on s.id = b.store_id
    left join public.managers m on m.id = s.root_manager_id
    where b.user_id = v_uid and b.status = 'active'
  ) t;
  return json_build_object('items', coalesce(v_items, '[]'::json));
end;
$function$;

create or replace function public.unbind_user_from_store(p_store_id uuid)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  update public.user_store_bindings
     set status = 'unbound', updated_at = now()
   where user_id = v_uid and store_id = p_store_id and status = 'active';
  return json_build_object('success', true);
end;
$function$;

create or replace function public.list_store_binding_customers(p_store_id uuid)
returns json
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_store public.stores%rowtype;
  v_root uuid;
  v_items json;
  v_total integer;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select * into v_store from public.stores where id = p_store_id;
  if not found then
    raise exception '门店不存在' using errcode = '22023';
  end if;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  if not exists (
    select 1 from public.store_members m
    where m.store_id = p_store_id and m.user_id = v_uid and m.status = 'active'
  ) and v_root is distinct from v_store.root_manager_id and not public.is_admin(v_uid) then
    raise exception '你没有查看这家门店顾客的权限' using errcode = '42501';
  end if;

  select count(*) into v_total
  from public.user_store_bindings b
  where b.store_id = p_store_id and b.status = 'active';

  select json_agg(t order by t.bound_at desc) into v_items
  from (
    select p.id as user_id, p.nickname, p.avatar_url,
           case
             when length(regexp_replace(p.phone, '[^0-9]', '', 'g')) = 11
             then substr(p.phone, 1, 3) || '****' || substr(p.phone, 8)
             else p.phone
           end as phone_masked,
           b.bound_at, b.last_visit_at
    from public.user_store_bindings b
    join public.profiles p on p.id = b.user_id
    where b.store_id = p_store_id and b.status = 'active'
  ) t;

  return json_build_object('items', coalesce(v_items, '[]'::json), 'total', v_total);
end;
$function$;

grant execute on function public.bind_user_to_store(uuid, boolean) to authenticated;
grant execute on function public.list_my_bound_stores() to authenticated;
grant execute on function public.unbind_user_from_store(uuid) to authenticated;
grant execute on function public.list_store_binding_customers(uuid) to authenticated;