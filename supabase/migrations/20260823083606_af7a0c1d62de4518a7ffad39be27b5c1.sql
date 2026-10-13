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
     and not public.is_admin(v_uid)
     and not (
       public.is_enterprise_admin(v_uid)
       and public.get_enterprise_root_manager_id(v_uid) = v_store.root_manager_id
     ) then
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

create or replace function public.set_store_status(p_store_id uuid, p_status text)
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
  if p_status not in ('active','disabled') then
    raise exception '状态值不合法' using errcode = '22023';
  end if;
  select * into v_store from public.stores where id = p_store_id;
  if not found then
    raise exception '门店不存在' using errcode = '22023';
  end if;

  if not public.is_admin(v_uid)
     and not (
       public.is_enterprise_admin(v_uid)
       and public.get_enterprise_root_manager_id(v_uid) = v_store.root_manager_id
     ) then
    raise exception '你没有管理这家门店的权限' using errcode = '42501';
  end if;

  update public.stores
     set status = p_status,
         disabled_at = case when p_status = 'disabled' then now() else null end,
         updated_at = now()
   where id = v_store.id;

  return json_build_object('success', true);
end;
$function$;

create or replace function public.set_store_product_grant(p_store_id uuid, p_product_id uuid, p_is_enabled boolean)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_store public.stores%rowtype;
  v_product public.products%rowtype;
  v_product_root uuid;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select * into v_store from public.stores where id = p_store_id;
  if not found then
    raise exception '门店不存在' using errcode = '22023';
  end if;

  if not public.is_admin(v_uid)
     and not (
       public.is_enterprise_admin(v_uid)
       and public.get_enterprise_root_manager_id(v_uid) = v_store.root_manager_id
     ) then
    raise exception '你没有管理这家门店的权限' using errcode = '42501';
  end if;

  select * into v_product from public.products where id = p_product_id;
  if not found or v_product.status <> 'active' then
    raise exception '商品不存在或已下架' using errcode = '22023';
  end if;
  if v_product.source_type <> 'manager' then
    raise exception '平台自营商品不能配到门店' using errcode = '22023';
  end if;
  if v_product.sale_mode <> 'cash' then
    raise exception '积分兑换商品不能配到门店' using errcode = '22023';
  end if;
  v_product_root := public.get_enterprise_root_manager_id(v_product.owner_manager_id);
  if v_product_root is distinct from v_store.root_manager_id then
    raise exception '只能勾选本企业自己的商品' using errcode = '42501';
  end if;

  insert into public.store_product_grants (store_id, product_id, is_enabled, created_by)
  values (v_store.id, v_product.id, coalesce(p_is_enabled, true), v_uid)
  on conflict (store_id, product_id)
  do update set is_enabled = coalesce(p_is_enabled, true),
                updated_at = now();

  return json_build_object('success', true);
end;
$function$;

create or replace function public.list_store_granted_products(p_store_id uuid)
returns json
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_store public.stores%rowtype;
  v_authorized boolean;
  v_items json;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select * into v_store from public.stores where id = p_store_id;
  if not found then
    raise exception '门店不存在' using errcode = '22023';
  end if;

  select (
    public.is_admin(v_uid)
    or (
      public.is_enterprise_admin(v_uid)
      and public.get_enterprise_root_manager_id(v_uid) = v_store.root_manager_id
    )
    or exists (
      select 1 from public.store_members m
      where m.store_id = v_store.id and m.user_id = v_uid and m.status = 'active'
    )
  ) into v_authorized;
  if not coalesce(v_authorized, false) then
    raise exception '你没有查看这家门店的权限' using errcode = '42501';
  end if;

  select json_agg(t order by t.updated_at desc) into v_items
  from (
    select g.product_id, g.is_enabled, g.updated_at
    from public.store_product_grants g
    where g.store_id = v_store.id
  ) t;
  return json_build_object('items', coalesce(v_items, '[]'::json));
end;
$function$;

create or replace function public.review_store_application(p_application_id uuid, p_action text, p_reason text default ''::text)
returns json
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_root uuid;
  v_app public.merchant_store_applications%rowtype;
  v_store_id uuid;
  v_code text;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  if p_action not in ('approve','reject') then
    raise exception '操作不合法' using errcode = '22023';
  end if;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  if v_root is null or not public.is_enterprise_admin(v_uid) then
    raise exception '只有企业管理员可以审核入驻申请' using errcode = '42501';
  end if;

  select * into v_app
  from public.merchant_store_applications
  where id = p_application_id
  for update;
  if not found then
    raise exception '申请不存在' using errcode = '22023';
  end if;
  if v_app.root_manager_id is distinct from v_root then
    raise exception '你不能审核其他商户的申请' using errcode = '42501';
  end if;
  if v_app.status <> 'pending' then
    raise exception '这份申请已经处理过了' using errcode = '22023';
  end if;

  if p_action = 'reject' then
    update public.merchant_store_applications
       set status = 'rejected',
           rejection_reason = btrim(coalesce(p_reason, '')),
           reviewed_by = v_uid,
           reviewed_at = now(),
           updated_at = now()
     where id = v_app.id;
    return json_build_object('success', true, 'action', 'rejected');
  end if;

  v_code := public._gen_store_code();
  insert into public.stores
    (root_manager_id, operator_user_id, short_code, name, phone,
     status, created_source, created_by)
  values
    (v_app.root_manager_id, v_app.applicant_user_id, v_code, v_app.store_name,
     v_app.contact_phone, 'active', 'application', v_uid)
  returning id into v_store_id;

  if v_app.applicant_user_id is not null then
    insert into public.store_members (store_id, user_id, role, status, created_at, updated_at)
    values (v_store_id, v_app.applicant_user_id, 'owner', 'active', now(), now())
    on conflict (store_id, user_id)
    do update set role = 'owner', status = 'active', updated_at = now();
  end if;

  update public.merchant_store_applications
     set status = 'approved',
         reviewed_by = v_uid,
         reviewed_at = now(),
         created_store_id = v_store_id,
         updated_at = now()
   where id = v_app.id;

  return json_build_object('success', true, 'action', 'approved', 'store_id', v_store_id);
end;
$function$;

grant execute on function public.update_store_profile(uuid, text, text, text, text, text, text) to authenticated;
grant execute on function public.set_store_status(uuid, text) to authenticated;
grant execute on function public.set_store_product_grant(uuid, uuid, boolean) to authenticated;
grant execute on function public.list_store_granted_products(uuid) to authenticated;
grant execute on function public.review_store_application(uuid, text, text) to authenticated;