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
  if v_root is null then
    raise exception '只有商户账号可以管理门店' using errcode = '42501';
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