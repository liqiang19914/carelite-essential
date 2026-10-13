-- 修正 owner_names 的类型：profiles.nickname 是 varchar，array_agg 出来是 varchar[]，
-- 与 RETURNS TABLE 声明的 text[] 不匹配，函数一被真正调用就报
-- 42804 structure of query does not match function result type。必须在聚合前显式转 text。
CREATE OR REPLACE FUNCTION public.manager_weighing_people(
  p_search text default null,
  p_from date default null,
  p_to date default null,
  p_limit integer default 20,
  p_offset integer default 0
)
RETURNS TABLE (
  record_id uuid,
  record_name text,
  client_id uuid,
  phone text,
  gender text,
  birth_date date,
  height numeric,
  measure_count bigint,
  last_measured_at timestamptz,
  owner_names text[],
  total_people bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_from timestamptz := CASE WHEN p_from IS NULL THEN NULL
                            ELSE (p_from::timestamp AT TIME ZONE 'Asia/Shanghai') END;
  v_to timestamptz := CASE WHEN p_to IS NULL THEN NULL
                          ELSE ((p_to + 1)::timestamp AT TIME ZONE 'Asia/Shanghai') END;
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  RETURN QUERY
  WITH caller AS (
    SELECT p.id,
           p.parent_manager_id,
           p.sub_role,
           p.role::text AS role,
           coalesce(p.is_disabled, false) AS disabled
    FROM public.profiles p
    WHERE p.id = v_uid
  ),
  caller_members AS (
    SELECT m.id AS manager_id
    FROM caller c
    JOIN public.profiles m ON m.role::text = 'manager'
    WHERE c.role = 'manager'
      AND c.disabled = false
      AND (
        (c.parent_manager_id IS NULL AND (m.id = c.id OR m.parent_manager_id = c.id))
        OR (c.sub_role = 'admin' AND c.parent_manager_id IS NOT NULL
             AND (m.id = c.parent_manager_id OR m.parent_manager_id = c.parent_manager_id))
        OR (c.parent_manager_id IS NOT NULL AND coalesce(c.sub_role, '') <> 'admin' AND m.id = c.id)
      )
  ),
  authorized_records AS (
    SELECT ra.record_id AS rid, hr.user_id AS cid
    FROM public.record_authorizations ra
    JOIN caller_members cm ON cm.manager_id = ra.manager_id
    JOIN public.health_records hr ON hr.id = ra.record_id
    JOIN public.client_relations cr
      ON cr.manager_id = ra.manager_id AND cr.client_id = hr.user_id
    WHERE ra.is_active = true
      AND (ra.expires_at IS NULL OR ra.expires_at > pg_catalog.now())
      AND cr.status = 'active'
      AND public.can_manager_view_client_category(hr.user_id, 'share_vitals')
    GROUP BY ra.record_id, hr.user_id
  ),
  filtered AS (
    SELECT bc.record_id AS rid, count(*) AS cnt, max(bc.measured_at) AS last_at
    FROM public.body_compositions bc
    JOIN authorized_records ar ON ar.rid = bc.record_id
    WHERE (v_from IS NULL OR bc.measured_at >= v_from)
      AND (v_to IS NULL OR bc.measured_at < v_to)
    GROUP BY bc.record_id
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
  SELECT c.rid,
         c.rname,
         c.cid,
         c.cphone,
         c.cgender,
         c.cbirth,
         c.cheight,
         c.cnt,
         c.last_at,
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