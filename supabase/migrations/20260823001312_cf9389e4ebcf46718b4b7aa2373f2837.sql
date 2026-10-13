drop function if exists public.get_manager_clients(uuid);

create or replace function public.get_manager_clients(p_manager_id uuid)
returns table(relation_id uuid, client_id uuid, status text, notes text, last_contact_at timestamp with time zone, relation_created_at timestamp with time zone, customer_name text, nickname text, phone text, avatar_url text, privacy_settings jsonb, shop_member_number text, shop_first_entered_at timestamp with time zone, store_name text)
language sql
stable security definer
set search_path to 'public'
as $function$
  with authorized as (
    select 1
    where auth.uid() = p_manager_id
       or is_admin(auth.uid())
       or is_enterprise_member_for_admin(p_manager_id, auth.uid())
  ),
  root_id as (
    select public.get_enterprise_root_manager_id(p_manager_id) as rid
  ),
  relation_rows as (
    select
      cr.id as relation_id,
      cr.client_id,
      cr.status::text,
      cr.notes,
      cr.last_contact_at,
      cr.created_at as relation_created_at,
      cr.customer_name
    from client_relations cr
    where cr.manager_id = p_manager_id
  ),
  member_only_rows as (
    select
      sm.id as relation_id,
      sm.client_id,
      'active'::text as status,
      ''::text as notes,
      null::timestamptz as last_contact_at,
      sm.first_entered_at as relation_created_at,
      null::text as customer_name
    from shop_members sm
    where sm.root_manager_id = (select rid from root_id)
      and sm.client_id not in (select r.client_id from relation_rows r)
  ),
  combined as (
    select * from relation_rows
    union all
    select * from member_only_rows
  )
  select
    c.relation_id,
    c.client_id,
    c.status,
    c.notes,
    c.last_contact_at,
    c.relation_created_at,
    coalesce(nullif(btrim(c.customer_name), ''), p.nickname::text, '未命名客户') as customer_name,
    p.nickname::text,
    case
      when public.is_admin(auth.uid()) then p.phone::text
      when p.phone ~ '^1[0-9]{10}$' then left(p.phone, 3) || '****' || right(p.phone, 4)
      else null
    end as phone,
    p.avatar_url,
    coalesce(p.privacy_settings, '{}'::jsonb) as privacy_settings,
    sm.member_number as shop_member_number,
    sm.first_entered_at as shop_first_entered_at,
    st.name::text as store_name
  from combined c
  cross join authorized
  left join profiles p on p.id = c.client_id
  left join shop_members sm
    on sm.root_manager_id = (select rid from root_id)
   and sm.client_id = c.client_id
  left join user_store_bindings b
    on b.user_id = c.client_id and b.status = 'active'
  left join stores st
    on st.id = b.store_id and st.root_manager_id = (select rid from root_id)
  order by c.relation_created_at desc;
$function$;

grant execute on function public.get_manager_clients(uuid) to authenticated;