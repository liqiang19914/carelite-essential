create or replace function public.claim_store(p_store_id uuid)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_store public.stores%rowtype;
  v_phone text;
  v_norm text;
  v_store_norm text;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;

  select * into v_store from public.stores where id = p_store_id;
  if not found then
    raise exception '门店不存在' using errcode = '22023';
  end if;
  if v_store.status <> 'active' then
    raise exception '这家门店已暂停营业，无法认领' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.store_members m
    where m.store_id = v_store.id and m.role = 'owner'
  ) then
    raise exception '这家门店已经有店主了' using errcode = '22023';
  end if;

  select phone into v_phone from public.profiles where id = v_uid;
  v_norm := regexp_replace(coalesce(v_phone, ''), '[^0-9]', '', 'g');
  v_store_norm := regexp_replace(coalesce(v_store.phone, ''), '[^0-9]', '', 'g');
  if v_norm = '' or v_norm <> v_store_norm then
    raise exception '只有门店登记的手机号本人才能认领这家店' using errcode = '42501';
  end if;

  insert into public.store_members (store_id, user_id, role, status, created_at, updated_at)
  values (v_store.id, v_uid, 'owner', 'active', now(), now())
  on conflict (store_id, user_id)
  do update set role = 'owner', status = 'active', updated_at = now();

  update public.stores
     set operator_user_id = coalesce(operator_user_id, v_uid),
         updated_at = now()
   where id = v_store.id;

  return json_build_object('success', true, 'store_id', v_store.id);
end;
$function$;

create or replace function public.list_claimable_stores()
returns json
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_phone text;
  v_items json;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select phone into v_phone from public.profiles where v_uid = id;
  if v_phone is null or btrim(v_phone) = '' then
    return json_build_object('items', '[]'::json);
  end if;

  select json_agg(t order by t.created_at desc) into v_items
  from (
    select s.id, s.name, s.phone, s.created_at, s.root_manager_id,
           m.business_name as merchant_name
    from public.stores s
    left join public.managers m on m.id = s.root_manager_id
    where not exists (
      select 1 from public.store_members sm
      where sm.store_id = s.id and sm.role = 'owner'
    )
      and s.status = 'active'
      and regexp_replace(s.phone, '[^0-9]', '', 'g') = regexp_replace(v_phone, '[^0-9]', '', 'g')
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
  v_root uuid;
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

  v_root := public.get_enterprise_root_manager_id(v_uid);
  select exists (
    select 1 from public.store_members m
    where m.store_id = v_store.id and m.user_id = v_uid
      and m.status = 'active' and m.role in ('owner','admin')
  ) into v_is_manager;

  if not coalesce(v_is_manager, false)
     and v_root is distinct from v_store.root_manager_id
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

grant execute on function public.list_my_stores() to authenticated;
grant execute on function public.list_my_store_orders(uuid, text, integer, integer) to authenticated;
grant execute on function public.verify_offline_store_order(uuid) to authenticated;
grant execute on function public.cancel_offline_store_order(uuid) to authenticated;
grant execute on function public.claim_store(uuid) to authenticated;
grant execute on function public.list_claimable_stores() to authenticated;
grant execute on function public.update_store_profile(uuid, text, text, text, text, text, text) to authenticated;