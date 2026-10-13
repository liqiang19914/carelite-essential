CREATE OR REPLACE FUNCTION public.manager_weighing_people(
  p_search text DEFAULT NULL::text,
  p_from date DEFAULT NULL::date,
  p_to date DEFAULT NULL::date,
  p_scale text DEFAULT NULL::text,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS TABLE(record_id uuid, record_name text, client_id uuid, phone text, gender text,
              birth_date date, height numeric, measure_count bigint,
              last_measured_at timestamp with time zone, owner_names text[], total_people bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_from timestamptz := CASE WHEN p_from IS NULL THEN NULL
                            ELSE (p_from::timestamp AT TIME ZONE 'Asia/Shanghai') END;
  v_to timestamptz := CASE WHEN p_to IS NULL THEN NULL
                          ELSE ((p_to + 1)::timestamp AT TIME ZONE 'Asia/Shanghai') END;
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_scale text := nullif(btrim(coalesce(p_scale, '')), '');
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  RETURN QUERY
  WITH caller_members AS (
    SELECT s.manager_id FROM public.oem_scope_manager_ids() s
  ),
  authorized_records AS (
    SELECT ra.record_id AS rid
    FROM public.record_authorizations ra
    JOIN caller_members cm ON cm.manager_id = ra.manager_id
    JOIN public.health_records hr ON hr.id = ra.record_id
    JOIN public.client_relations cr
      ON cr.manager_id = ra.manager_id AND cr.client_id = hr.user_id
    WHERE ra.is_active = true
      AND (ra.expires_at IS NULL OR ra.expires_at > pg_catalog.now())
      AND cr.status = 'active'
      AND public.can_manager_view_client_category(hr.user_id, 'share_vitals')
    GROUP BY ra.record_id
  ),
  visible AS (
    SELECT bc.record_id AS rid, bc.measured_at
    FROM public.body_compositions bc
    WHERE (v_from IS NULL OR bc.measured_at >= v_from)
      AND (v_to IS NULL OR bc.measured_at < v_to)
      AND (v_scale IS NULL OR bc.provider_key = v_scale OR bc.origin = v_scale)
      AND (
        (bc.oem_manager_id IN (SELECT cm.manager_id FROM caller_members cm)
          AND public.record_vitals_shared(bc.record_id))
        OR (bc.oem_manager_id IS NULL
          AND bc.record_id IN (SELECT ar.rid FROM authorized_records ar))
      )
  ),
  filtered AS (
    SELECT v.rid, count(*) AS cnt, max(v.measured_at) AS last_at
    FROM visible v
    GROUP BY v.rid
  ),
  joined AS (
    SELECT f.rid,
           hr.name::text AS rname,
           hr.user_id AS cid,
           pr.phone::text AS cphone,
           hr.gender::text AS cgender,
           hr.birth_date AS cbirth,
           hr.height AS cheight,
           f.cnt,
           f.last_at
    FROM filtered f
    JOIN public.health_records hr ON hr.id = f.rid
    LEFT JOIN public.profiles pr ON pr.id = hr.user_id
    WHERE (v_search IS NULL
           OR hr.name ILIKE '%' || v_search || '%'
           OR coalesce(pr.phone, '') ILIKE '%' || v_search || '%')
  ),
  counted AS (
    SELECT j.*, count(*) OVER () AS total_cnt FROM joined j
  )
  SELECT c.rid, c.rname, c.cid, c.cphone, c.cgender, c.cbirth, c.cheight, c.cnt, c.last_at,
         coalesce((
           SELECT array_agg(DISTINCT coalesce(mp.nickname::text, '未命名'))
           FROM public.client_relations cr2
           JOIN caller_members cm2 ON cm2.manager_id = cr2.manager_id
           JOIN public.profiles mp ON mp.id = cr2.manager_id
           WHERE cr2.client_id = c.cid AND cr2.status = 'active'
         ), array[]::text[]),
         c.total_cnt
  FROM counted c
  ORDER BY c.last_at DESC
  LIMIT v_limit OFFSET v_offset;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_weighing_people(
  p_manager_id uuid default null,
  p_search text default null,
  p_from date default null,
  p_to date default null,
  p_scale text default null,
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
  v_scale text := nullif(btrim(coalesce(p_scale, '')), '');
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
      and (v_scale is null or bc.provider_key = v_scale or bc.origin = v_scale)
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