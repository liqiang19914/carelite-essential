create or replace function public.list_enterprise_manager_products(p_manager_id uuid)
returns table (
  id uuid,
  title text,
  cover_image_url text,
  price_cents bigint
)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_caller uuid := auth.uid();
  v_enterprise_id uuid;
begin
  select m.enterprise_id into v_enterprise_id
  from public.managers m where m.id = p_manager_id limit 1;
  if v_enterprise_id is null then
    raise exception '该健管师档案不存在' using errcode = 'P0002';
  end if;

  -- 平台超管可代查；其余只允许本企业成员
  if v_caller is not null and public.is_admin(v_caller) then
    null;
  elsif not exists (
    select 1 from public.managers cm
    where cm.id = v_caller and cm.enterprise_id = v_enterprise_id
  ) then
    raise exception '只能查看本企业商品' using errcode = '42501';
  end if;

  return query
  select p.id, p.title, p.cover_image_url, sku.price_cents
  from public.products p
  join public.managers om
    on om.id = p.owner_manager_id and om.enterprise_id = v_enterprise_id
  left join lateral (
    select s.price_cents
    from public.product_skus s
    where s.product_id = p.id and s.is_default and s.is_active
    limit 1
  ) sku on true
  where p.source_type = 'manager' and p.status = 'active'
  order by p.created_at desc
  limit 100;
end;
$function$;

grant execute on function public.list_enterprise_manager_products(uuid) to authenticated;