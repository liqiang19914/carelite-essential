drop function if exists public.get_enterprise_clients_with_owner(integer, integer, text, uuid);

create or replace function public.get_enterprise_clients_with_owner(p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_search text DEFAULT NULL::text, p_owner_manager_id uuid DEFAULT NULL::uuid)
returns table(relation_id uuid, client_id uuid, status text, notes text, last_contact_at timestamp with time zone, relation_created_at timestamp with time zone, customer_name text, nickname text, phone text, avatar_url text, privacy_settings jsonb, owner_manager_id uuid, owner_manager_nickname text, owner_manager_phone text, owner_sub_role text, owner_is_disabled boolean, shop_member_number text, shop_first_entered_at timestamp with time zone, store_name text, total_count bigint)
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_is_admin boolean;
  v_root uuid;
  v_limit int;
  v_offset int;
  v_search text;
begin
  if v_uid is null then
    raise exception '未登录' using errcode = '28000';
  end if;

  select public.is_enterprise_admin(v_uid) into v_is_admin;
  if not v_is_admin then
    raise exception '仅企业管理员可访问' using errcode = '42501';
  end if;

  select public.get_enterprise_root_manager_id(v_uid) into v_root;
  if v_root is null then
    return;
  end if;

  v_limit := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_offset := greatest(coalesce(p_offset, 0), 0);
  v_search := nullif(trim(coalesce(p_search, '')), '');

  return query
  with members as (
    select v_root as mid
    union
    select p.id
    from public.profiles p
    where p.parent_manager_id = v_root and p.role = 'manager'
  ),
  relation_scoped as (
    select
      cr.id as relation_id,
      cr.client_id,
      cr.status::text as status,
      cr.notes,
      cr.last_contact_at,
      cr.created_at as relation_created_at,
      cr.manager_id as owner_manager_id,
      cr.customer_name
    from public.client_relations cr
    where cr.manager_id in (select mid from members)
      and (p_owner_manager_id is null or cr.manager_id = p_owner_manager_id)
      and (
        v_search is null
        or exists (
          select 1 from public.profiles cp
          where cp.id = cr.client_id
            and (cp.nickname ilike '%' || v_search || '%'
                 or cp.phone ilike '%' || v_search || '%')
        )
        or cr.customer_name ilike '%' || v_search || '%'
      )
  ),
  member_only as (
    select
      sm.id as relation_id,
      sm.client_id,
      'active'::text as status,
      ''::text as notes,
      null::timestamptz as last_contact_at,
      sm.first_entered_at as relation_created_at,
      v_root as owner_manager_id,
      null::text as customer_name
    from public.shop_members sm
    where sm.root_manager_id = v_root
      and sm.client_id not in (select r.client_id from relation_scoped r)
      and (
        v_search is null
        or exists (
          select 1 from public.profiles cp
          where cp.id = sm.client_id
            and (cp.nickname ilike '%' || v_search || '%'
                 or cp.phone ilike '%' || v_search || '%')
        )
      )
  ),
  combined as (
    select * from relation_scoped
    union all
    select * from member_only
  )
  select
    c.relation_id,
    c.client_id,
    c.status,
    c.notes,
    c.last_contact_at,
    c.relation_created_at,
    coalesce(nullif(btrim(c.customer_name), ''), cp.nickname::text, '未命名客户') as customer_name,
    cp.nickname::text,
    case
      when public.is_admin(v_uid) then cp.phone::text
      when cp.phone ~ '^1[0-9]{10}$' then left(cp.phone, 3) || '****' || right(cp.phone, 4)
      else null
    end as phone,
    cp.avatar_url,
    coalesce(cp.privacy_settings, '{}'::jsonb) as privacy_settings,
    c.owner_manager_id,
    op.nickname::text as owner_manager_nickname,
    op.phone::text as owner_manager_phone,
    coalesce(op.sub_role, '')::text as owner_sub_role,
    coalesce(op.is_disabled, false) as owner_is_disabled,
    sm.member_number as shop_member_number,
    sm.first_entered_at as shop_first_entered_at,
    st.name::text as store_name,
    count(*) over() as total_count
  from combined c
  left join public.profiles cp on cp.id = c.client_id
  left join public.profiles op on op.id = c.owner_manager_id
  left join public.shop_members sm
    on sm.root_manager_id = v_root
   and sm.client_id = c.client_id
  left join public.user_store_bindings b
    on b.user_id = c.client_id and b.status = 'active'
  left join public.stores st
    on st.id = b.store_id and st.root_manager_id = v_root
  order by c.relation_created_at desc
  limit v_limit
  offset v_offset;
end;
$function$;

grant execute on function public.get_enterprise_clients_with_owner(integer, integer, text, uuid) to authenticated;