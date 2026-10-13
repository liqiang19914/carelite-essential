-- 商户端称重数据台：按人聚合列表 + 概览
-- 与平台端 admin_weighing_people 的关键差别：平台端先对全表分组（admin 本来看全部，那是对的），
-- 商户端必须先算出「可见档案集」再聚合，否则一个只有百来位客户的商户会去扫全表。
-- 隐私闸门（档案授权 active 且未过期 + 客户关系 active + 客户未关闭体征共享）放在
-- authorized_records 这一层做一次集合连接，而不是每行调一次布尔函数。

-- 授权表按 manager 找 record 的覆盖索引（原有索引只到 manager_id，还要回表取 record_id）
CREATE INDEX IF NOT EXISTS idx_record_authorizations_manager_active
  ON public.record_authorizations (manager_id, record_id)
  WHERE is_active = true;

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
  -- 日期区间按中国自然日换算成绝对时间点，这样比较仍然走 body_compositions(record_id, measured_at) 索引
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
  -- 调用者能代表哪些管理师。口径与 is_enterprise_member_for_admin 完全一致：
  -- 企业主 = 自己 + 直属员工；sub_role='admin' 员工 = 企业主 + 同企业全部员工；
  -- 普通员工 / 单体商户 = 只有自己。
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
  -- 隐私闸门就在这一层：档案授权 active 且未过期 + 客户关系 active + 客户未关闭体征共享
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
         -- 归属员工名单只在调用者自己企业内取，绝不带出企业外那家商户的名字
         coalesce((
           SELECT array_agg(DISTINCT coalesce(mp.nickname, '未命名'))
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

CREATE OR REPLACE FUNCTION public.manager_weighing_overview()
RETURNS TABLE (
  today_count bigint,
  people_count bigint,
  total_count bigint,
  provider_counts jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_today_start timestamptz :=
    (((pg_catalog.now() AT TIME ZONE 'Asia/Shanghai')::date)::timestamp AT TIME ZONE 'Asia/Shanghai');
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
  scoped AS (
    SELECT bc.record_id, bc.measured_at, bc.provider_key
    FROM public.body_compositions bc
    JOIN authorized_records ar ON ar.rid = bc.record_id
  )
  SELECT
    (SELECT count(*) FROM scoped s WHERE s.measured_at >= v_today_start),
    (SELECT count(DISTINCT s.record_id) FROM scoped s),
    (SELECT count(*) FROM scoped s),
    coalesce((
      SELECT jsonb_object_agg(t.provider_key, t.cnt)
      FROM (SELECT s.provider_key, count(*) AS cnt FROM scoped s GROUP BY s.provider_key) t
    ), '{}'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.manager_weighing_people(text, date, date, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.manager_weighing_people(text, date, date, integer, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.manager_weighing_people(text, date, date, integer, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.manager_weighing_overview() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.manager_weighing_overview() FROM anon;
GRANT EXECUTE ON FUNCTION public.manager_weighing_overview() TO authenticated;

COMMENT ON FUNCTION public.manager_weighing_people(text, date, date, integer, integer) IS
  '商户端称重数据：按人聚合。范围由调用者自身身份推导（单体商户/普通员工=自己；企业主或 sub_role=admin 员工=全企业），并强制档案授权 active 未过期 + 客户关系 active + 客户 share_vitals 未关闭。';
COMMENT ON FUNCTION public.manager_weighing_overview() IS
  '商户端称重数据概览：今日次数/有数据客户数/累计次数/各秤占比，范围与 manager_weighing_people 完全一致。';