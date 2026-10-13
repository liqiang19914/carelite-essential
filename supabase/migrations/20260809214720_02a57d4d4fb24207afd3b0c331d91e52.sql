-- 修正：nickname 是 varchar，array_agg 出来的是 varchar[]，与声明的 text[] 不匹配，需显式转 text
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
           select array_agg(distinct coalesce(mp.nickname::text, '未命名商户'))
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