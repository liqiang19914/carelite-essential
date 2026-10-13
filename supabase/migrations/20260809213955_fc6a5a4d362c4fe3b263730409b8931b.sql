-- 平台端称重数据总览：按人聚合的列表查询（先定位到人，避免全表铺开）
create or replace function public.admin_weighing_people(
  p_manager_id uuid default null,
  p_search text default null,
  p_from date default null,
  p_to date default null,
  p_limit integer default 20,
  p_offset integer default 0
)
returns table (
  record_id uuid,
  record_name text,
  client_id uuid,
  phone text,
  gender text,
  birth_date date,
  height numeric,
  measure_count bigint,
  last_measured_at timestamptz,
  manager_names text[],
  total_people bigint
)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  -- 日期区间按中国时区的自然日换算成绝对时间点，这样比较仍然能用 measured_at 索引
  v_from timestamptz := case when p_from is null then null
                            else (p_from::timestamp at time zone 'Asia/Shanghai') end;
  v_to timestamptz := case when p_to is null then null
                          else ((p_to + 1)::timestamp at time zone 'Asia/Shanghai') end;
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not_admin';
  end if;

  return query
  with filtered as (
    select bc.record_id as rid, count(*) as cnt, max(bc.measured_at) as last_at
    from public.body_compositions bc
    where (v_from is null or bc.measured_at >= v_from)
      and (v_to is null or bc.measured_at < v_to)
    group by bc.record_id
  ),
  joined as (
    select f.rid,
           hr.name::text as rname,
           hr.user_id as cid,
           pr.phone::text as cphone,
           hr.gender::text as cgender,
           hr.birth_date as cbirth,
           hr.height as cheight,
           f.cnt,
           f.last_at
    from filtered f
    join public.health_records hr on hr.id = f.rid
    left join public.profiles pr on pr.id = hr.user_id
    where (p_manager_id is null or exists (
             select 1 from public.client_relations cr
             where cr.client_id = hr.user_id
               and cr.manager_id = p_manager_id
               and cr.status = 'active'))
      and (v_search is null
           or hr.name ilike '%' || v_search || '%'
           or coalesce(pr.phone, '') ilike '%' || v_search || '%')
  ),
  counted as (
    select j.*, count(*) over () as total_cnt from joined j
  )
  select c.rid,
         c.rname,
         c.cid,
         c.cphone,
         c.cgender,
         c.cbirth,
         c.cheight,
         c.cnt,
         c.last_at,
         coalesce((
           select array_agg(distinct coalesce(mp.nickname, '未命名商户'))
           from public.client_relations cr2
           join public.profiles mp on mp.id = cr2.manager_id
           where cr2.client_id = c.cid and cr2.status = 'active'
         ), array[]::text[]),
         c.total_cnt
  from counted c
  order by c.last_at desc
  limit v_limit offset v_offset;
end;
$function$;

-- 仪表盘概览卡：今日测量次数、有数据的商户数、有数据的人数、两款秤各自的占比
create or replace function public.admin_weighing_overview()
returns table (
  today_count bigint,
  merchant_count bigint,
  people_count bigint,
  total_count bigint,
  provider_counts jsonb
)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_today_start timestamptz :=
    (((now() at time zone 'Asia/Shanghai')::date)::timestamp at time zone 'Asia/Shanghai');
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not_admin';
  end if;

  return query
  select
    (select count(*) from public.body_compositions bc where bc.measured_at >= v_today_start),
    (select count(distinct cr.manager_id)
       from public.body_compositions bc
       join public.health_records hr on hr.id = bc.record_id
       join public.client_relations cr on cr.client_id = hr.user_id and cr.status = 'active'),
    (select count(distinct bc.record_id) from public.body_compositions bc),
    (select count(*) from public.body_compositions bc),
    coalesce((
      select jsonb_object_agg(t.provider_key, t.cnt)
      from (
        select bc.provider_key, count(*) as cnt
        from public.body_compositions bc
        group by bc.provider_key
      ) t
    ), '{}'::jsonb);
end;
$function$;

grant execute on function public.admin_weighing_people(uuid, text, date, date, integer, integer) to authenticated;
grant execute on function public.admin_weighing_overview() to authenticated;