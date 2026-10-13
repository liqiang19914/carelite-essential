-- ① 存量商城会员补建客户关系（默认归企业根）
--    回填期间临时停用套餐客户数触发器：这些人本来就是会员，补关系不该被上限挡住
alter table public.client_relations disable trigger trg_enforce_membership_client_limit;

insert into public.client_relations (manager_id, client_id, root_manager_id, status, created_at, updated_at)
select sm.root_manager_id, sm.client_id, sm.root_manager_id, 'active', coalesce(sm.first_entered_at, now()), now()
from public.shop_members sm
where not exists (
  select 1 from public.client_relations cr
  where cr.root_manager_id = sm.root_manager_id and cr.client_id = sm.client_id
)
on conflict do nothing;

alter table public.client_relations enable trigger trg_enforce_membership_client_limit;

-- 存量关系补企业根归属（老数据 root_manager_id 为空时按负责人所属企业回填）
update public.client_relations cr
   set root_manager_id = public.get_enterprise_root_manager_id(cr.manager_id)
 where cr.root_manager_id is null;

-- ② 跟进提醒字段与索引
alter table public.follow_up_records
  add column if not exists next_follow_up_at timestamptz,
  add column if not exists reminder boolean not null default false,
  add column if not exists reminded_at timestamptz,
  add column if not exists created_by uuid;

create index if not exists idx_follow_up_records_due
  on public.follow_up_records (next_follow_up_at)
  where reminder and reminded_at is null;

create index if not exists idx_follow_up_records_relation_due
  on public.follow_up_records (client_relation_id, next_follow_up_at desc);

-- ③ 站内通知去重键（跟进提醒每日扫描防重复）
alter table public.notifications add column if not exists dedupe_key text;

create unique index if not exists uq_notifications_dedupe_key
  on public.notifications (dedupe_key)
  where dedupe_key is not null;

-- ④ 记跟进（安全写入，管理员可代记）
create or replace function public.add_client_follow_up(
  p_relation_id uuid,
  p_content text,
  p_follow_up_type text default null,
  p_next_follow_up_at timestamptz default null,
  p_reminder boolean default false
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_rel public.client_relations%rowtype;
  v_root uuid;
  v_new_id uuid;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '28000';
  end if;
  if p_relation_id is null then
    raise exception '缺少客户信息' using errcode = '22023';
  end if;
  if nullif(btrim(coalesce(p_content, '')), '') is null then
    raise exception '请填写跟进内容' using errcode = '22023';
  end if;
  if coalesce(p_reminder, false) and p_next_follow_up_at is null then
    raise exception '开启提醒需要设置下次跟进时间' using errcode = '22023';
  end if;

  select * into v_rel
  from public.client_relations
  where id = p_relation_id;

  if v_rel.id is null then
    raise exception '未找到该客户' using errcode = '22023';
  end if;

  v_root := public.get_enterprise_root_manager_id(v_uid);

  if v_rel.manager_id is distinct from v_uid
     and not (
       public.is_enterprise_admin(v_uid)
       and v_rel.root_manager_id is not distinct from v_root
     ) then
    raise exception '只能为自己负责的客户记跟进' using errcode = '42501';
  end if;

  insert into public.follow_up_records
    (client_relation_id, content, follow_up_type, next_follow_up_at, reminder, created_by)
  values
    (p_relation_id, btrim(p_content), nullif(btrim(coalesce(p_follow_up_type, '')), ''),
     p_next_follow_up_at, coalesce(p_reminder, false), v_uid)
  returning id into v_new_id;

  update public.client_relations
     set last_contact_at = now(), updated_at = now()
   where id = p_relation_id;

  return v_new_id;
end;
$function$;

-- ⑤ 修改跟进提醒（改时间/重新开启 → 重置已提醒标记）
create or replace function public.update_follow_up_reminder(
  p_record_id uuid,
  p_content text default null,
  p_follow_up_type text default null,
  p_next_follow_up_at timestamptz default null,
  p_reminder boolean default null
)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_rec record;
  v_root uuid;
  v_new_reminder boolean;
  v_new_next timestamptz;
  v_time_changed boolean;
  v_reset_reminded boolean := false;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '28000';
  end if;
  if p_record_id is null then
    raise exception '缺少跟进记录' using errcode = '22023';
  end if;

  select fr.reminder, fr.next_follow_up_at,
         cr.manager_id, cr.root_manager_id
    into v_rec
  from public.follow_up_records fr
  join public.client_relations cr on cr.id = fr.client_relation_id
  where fr.id = p_record_id;

  if v_rec.root_manager_id is null then
    raise exception '未找到该跟进记录' using errcode = '22023';
  end if;

  v_root := public.get_enterprise_root_manager_id(v_uid);

  if v_rec.manager_id is distinct from v_uid
     and not (
       public.is_enterprise_admin(v_uid)
       and v_rec.root_manager_id is not distinct from v_root
     ) then
    raise exception '只能修改自己负责客户的跟进记录' using errcode = '42501';
  end if;

  v_new_reminder := coalesce(p_reminder, v_rec.reminder);
  v_new_next := p_next_follow_up_at;
  v_time_changed := (p_next_follow_up_at is distinct from v_rec.next_follow_up_at);

  if v_new_reminder and v_new_next is null then
    raise exception '开启提醒需要设置下次跟进时间' using errcode = '22023';
  end if;

  if v_new_reminder and (coalesce(p_reminder, false) or v_time_changed) then
    v_reset_reminded := true;
  end if;

  update public.follow_up_records
     set content = coalesce(p_content, content),
         follow_up_type = coalesce(nullif(btrim(coalesce(p_follow_up_type, '')), ''), follow_up_type),
         next_follow_up_at = v_new_next,
         reminder = v_new_reminder,
         reminded_at = case when v_reset_reminded then null else reminded_at end
   where id = p_record_id;

  return true;
end;
$function$;

-- ⑥ 进店登记会员时同步补建客户归属关系（best-effort，不阻塞会员登记）
create or replace function public.register_shop_member(p_root_manager_id uuid)
returns table(member_id uuid, member_number text, first_entered_at timestamp with time zone, created boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_sequence bigint;
  v_prefix text;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.profiles
    where id = v_uid and role::text = 'user' and coalesce(is_disabled, false) = false
  ) then
    raise exception '当前账号不能登记商城会员' using errcode = '42501';
  end if;

  if public.get_enterprise_root_manager_id(p_root_manager_id) is distinct from p_root_manager_id
     or not public.is_public_enterprise_content_root(p_root_manager_id) then
    raise exception '商城不存在或已停用' using errcode = '22023';
  end if;

  return query
  select sm.id, sm.member_number, sm.first_entered_at, false
  from public.shop_members sm
  where sm.root_manager_id = p_root_manager_id and sm.client_id = v_uid;
  if found then return; end if;

  insert into public.shop_member_counters(root_manager_id, last_value)
  values (p_root_manager_id, 1)
  on conflict (root_manager_id) do update
    set last_value = public.shop_member_counters.last_value + 1
  returning last_value into v_sequence;

  v_prefix := public.shop_member_prefix(p_root_manager_id);

  return query
  insert into public.shop_members(root_manager_id, client_id, member_sequence, member_number)
  values (p_root_manager_id, v_uid, v_sequence, v_prefix || '-' || lpad(v_sequence::text, 6, '0'))
  on conflict (root_manager_id, client_id) do nothing
  returning shop_members.id, shop_members.member_number, shop_members.first_entered_at, true;

  begin
    insert into public.client_relations (manager_id, client_id, root_manager_id, status, created_at, updated_at)
    values (p_root_manager_id, v_uid, p_root_manager_id, 'active', now(), now())
    on conflict do nothing;
  exception when others then
    null;
  end;

  if not found then
    return query
    select sm.id, sm.member_number, sm.first_entered_at, false
    from public.shop_members sm
    where sm.root_manager_id = p_root_manager_id and sm.client_id = v_uid;
  end if;
end;
$function$;

-- ⑦ 企业客户列表：新筛选签名 + 真实关系 ID + 手机号规则 + 提醒状态
drop function if exists public.get_enterprise_clients_with_owner(integer, integer, text, uuid);

create or replace function public.get_enterprise_clients_with_owner(
  p_limit integer default 50,
  p_offset integer default 0,
  p_search text default null,
  p_owner_manager_id uuid default null,
  p_created_from date default null,
  p_created_to date default null,
  p_reminder_from date default null,
  p_reminder_to date default null
)
returns table(
  relation_id uuid,
  client_id uuid,
  status text,
  notes text,
  last_contact_at timestamp with time zone,
  relation_created_at timestamp with time zone,
  customer_name text,
  nickname text,
  phone text,
  avatar_url text,
  privacy_settings jsonb,
  owner_manager_id uuid,
  owner_manager_nickname text,
  owner_manager_phone text,
  owner_sub_role text,
  owner_is_disabled boolean,
  shop_member_number text,
  shop_first_entered_at timestamp with time zone,
  store_name text,
  next_reminder_at timestamp with time zone,
  reminder_status text,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_root uuid;
  v_limit int;
  v_offset int;
  v_search text;
  v_today date;
begin
  if v_uid is null then
    raise exception '未登录' using errcode = '28000';
  end if;

  if not public.is_enterprise_admin(v_uid) then
    raise exception '仅企业管理员可访问' using errcode = '42501';
  end if;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  if v_root is null then
    return;
  end if;

  v_limit := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_offset := greatest(coalesce(p_offset, 0), 0);
  v_search := nullif(trim(coalesce(p_search, '')), '');
  v_today := (now() at time zone 'Asia/Shanghai')::date;

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
      and (p_created_from is null or (cr.created_at at time zone 'Asia/Shanghai')::date >= p_created_from)
      and (p_created_to is null or (cr.created_at at time zone 'Asia/Shanghai')::date <= p_created_to)
  ),
  with_reminder as (
    select
      c.*,
      rem.next_reminder_at
    from relation_scoped c
    left join lateral (
      select fr.next_follow_up_at as next_reminder_at
      from public.follow_up_records fr
      where fr.client_relation_id = c.relation_id
        and fr.reminder
        and fr.next_follow_up_at is not null
      order by fr.next_follow_up_at desc
      limit 1
    ) rem on true
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
      when coalesce(cp.privacy_settings->>'show_phone', 'true') = 'false' then null
      when public.is_admin(v_uid) then cp.phone::text
      when public.is_enterprise_admin(v_uid) then cp.phone::text
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
    c.next_reminder_at,
    case
      when c.next_reminder_at is null then 'none'
      when (c.next_reminder_at at time zone 'Asia/Shanghai')::date < v_today then 'overdue'
      when (c.next_reminder_at at time zone 'Asia/Shanghai')::date = v_today then 'today'
      else 'upcoming'
    end as reminder_status,
    count(*) over() as total_count
  from with_reminder c
  left join public.profiles cp on cp.id = c.client_id
  left join public.profiles op on op.id = c.owner_manager_id
  left join public.shop_members sm
    on sm.root_manager_id = v_root and sm.client_id = c.client_id
  left join public.user_store_bindings b
    on b.user_id = c.client_id and b.status = 'active'
  left join public.stores st
    on st.id = b.store_id and st.root_manager_id = v_root
  where (p_reminder_from is null or (c.next_reminder_at at time zone 'Asia/Shanghai')::date >= p_reminder_from)
    and (p_reminder_to is null or (c.next_reminder_at at time zone 'Asia/Shanghai')::date <= p_reminder_to)
  order by c.relation_created_at desc
  limit v_limit
  offset v_offset;
end;
$function$;

-- ⑧ 员工本人客户列表：真实关系 ID + 手机号规则 + 提醒状态
drop function if exists public.get_manager_clients(uuid);

create or replace function public.get_manager_clients(p_manager_id uuid)
returns table(
  relation_id uuid,
  client_id uuid,
  status text,
  notes text,
  last_contact_at timestamp with time zone,
  relation_created_at timestamp with time zone,
  customer_name text,
  nickname text,
  phone text,
  avatar_url text,
  privacy_settings jsonb,
  shop_member_number text,
  shop_first_entered_at timestamp with time zone,
  store_name text,
  next_reminder_at timestamp with time zone,
  reminder_status text
)
language sql
stable
security definer
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
  with_reminder as (
    select c.*, rem.next_reminder_at
    from relation_rows c
    left join lateral (
      select fr.next_follow_up_at as next_reminder_at
      from follow_up_records fr
      where fr.client_relation_id = c.relation_id
        and fr.reminder
        and fr.next_follow_up_at is not null
      order by fr.next_follow_up_at desc
      limit 1
    ) rem on true
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
      when coalesce(p.privacy_settings->>'show_phone', 'true') = 'false' then null
      when public.is_admin(auth.uid()) then p.phone::text
      when exists (
        select 1 from public.profiles caller
        where caller.id = auth.uid()
          and caller.role = 'manager'
          and coalesce(caller.is_disabled, false) = false
          and (caller.parent_manager_id is null or caller.sub_role = 'admin')
          and public.get_enterprise_root_manager_id(caller.id) = (select rid from root_id)
      ) then p.phone::text
      when p.phone ~ '^1[0-9]{10}$' then left(p.phone, 3) || '****' || right(p.phone, 4)
      else null
    end as phone,
    p.avatar_url,
    coalesce(p.privacy_settings, '{}'::jsonb) as privacy_settings,
    sm.member_number as shop_member_number,
    sm.first_entered_at as shop_first_entered_at,
    st.name::text as store_name,
    c.next_reminder_at,
    case
      when c.next_reminder_at is null then 'none'
      when (c.next_reminder_at at time zone 'Asia/Shanghai')::date < ((now() at time zone 'Asia/Shanghai')::date) then 'overdue'
      when (c.next_reminder_at at time zone 'Asia/Shanghai')::date = ((now() at time zone 'Asia/Shanghai')::date) then 'today'
      else 'upcoming'
    end as reminder_status
  from with_reminder c
  cross join authorized
  left join profiles p on p.id = c.client_id
  left join shop_members sm
    on sm.root_manager_id = (select rid from root_id) and sm.client_id = c.client_id
  left join user_store_bindings b
    on b.user_id = c.client_id and b.status = 'active'
  left join stores st
    on st.id = b.store_id and st.root_manager_id = (select rid from root_id)
  order by c.relation_created_at desc;
$function$;

-- ⑨ 权限
grant execute on function public.add_client_follow_up(uuid, text, text, timestamptz, boolean) to authenticated;
grant execute on function public.update_follow_up_reminder(uuid, text, text, timestamptz, boolean) to authenticated;
grant execute on function public.get_enterprise_clients_with_owner(integer, integer, text, uuid, date, date, date, date) to authenticated;
grant execute on function public.get_manager_clients(uuid) to authenticated;