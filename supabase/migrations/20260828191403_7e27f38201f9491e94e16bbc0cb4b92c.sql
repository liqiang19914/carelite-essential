-- 修复：六个通道仍以授权表为数据入口，无授权行时在调用 record_is_authorized 之前
-- 就已返回空集，「无授权行=默认已授权」没有真正生效。
-- 改为以 client_relations + health_records 为候选入口，再用 record_is_authorized
-- 逐对判定（无行放行、显式关闭与过期仍拦截）。其余条件不变。

-- 1) 行级策略：员工本人看自己客户的体成分
CREATE OR REPLACE FUNCTION public.can_current_manager_view_body_composition(p_record_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.health_records hr
    JOIN public.client_relations cr
      ON cr.client_id = hr.user_id AND cr.manager_id = auth.uid()
    WHERE hr.id = p_record_id
      AND cr.status = 'active'
      AND public.can_manager_view_client_category(hr.user_id, 'share_vitals')
      AND public.record_is_authorized(hr.id, cr.manager_id)
  );
$function$;

REVOKE ALL ON FUNCTION public.can_current_manager_view_body_composition(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_current_manager_view_body_composition(uuid) TO authenticated;

-- 2) 行级策略：企业主 / 企业管理员看全企业员工的客户体成分
CREATE OR REPLACE FUNCTION public.can_current_enterprise_admin_view_body_composition(p_record_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.health_records hr
    JOIN public.client_relations cr ON cr.client_id = hr.user_id
    WHERE hr.id = p_record_id
      AND cr.status = 'active'
      AND public.can_manager_view_client_category(hr.user_id, 'share_vitals')
      AND public.is_enterprise_member_for_admin(cr.manager_id, (SELECT auth.uid()))
      AND public.record_is_authorized(hr.id, cr.manager_id)
  );
$function$;

REVOKE ALL ON FUNCTION public.can_current_enterprise_admin_view_body_composition(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_current_enterprise_admin_view_body_composition(uuid) TO authenticated;

-- 3) 商户端称重数据名单（RETURNS TABLE，签名不变照计划 DROP 后重建）
DROP FUNCTION IF EXISTS public.manager_weighing_people(text, date, date, text, text, integer, integer);

CREATE FUNCTION public.manager_weighing_people(
  p_search text DEFAULT NULL::text,
  p_from date DEFAULT NULL::date,
  p_to date DEFAULT NULL::date,
  p_scale text DEFAULT NULL::text,
  p_bmi_status text DEFAULT NULL::text,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS TABLE(record_id uuid, record_name text, client_id uuid, phone text, gender text,
              birth_date date, height numeric, measure_count bigint,
              last_measured_at timestamp with time zone, owner_names text[],
              bmi_status text, total_people bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_from timestamptz := CASE WHEN p_from IS NULL THEN NULL
                            ELSE (p_from::timestamp AT TIME ZONE 'Asia/Shanghai') END;
  v_to timestamptz := CASE WHEN p_to IS NULL THEN NULL
                          ELSE ((p_to + 1)::timestamp AT TIME ZONE 'Asia/Shanghai') END;
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_scale text := nullif(btrim(coalesce(p_scale, '')), '');
  v_bmi text := nullif(btrim(coalesce(p_bmi_status, '')), '');
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
    SELECT hr.id AS rid
    FROM public.health_records hr
    JOIN public.client_relations cr ON cr.client_id = hr.user_id
    JOIN caller_members cm ON cm.manager_id = cr.manager_id
    WHERE cr.status = 'active'
      AND public.can_manager_view_client_category(hr.user_id, 'share_vitals')
      AND public.record_is_authorized(hr.id, cr.manager_id)
    GROUP BY hr.id
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
  weighted AS (
    SELECT j.*,
           (SELECT bc.weight
            FROM public.body_compositions bc
            WHERE bc.record_id = j.rid
              AND bc.weight IS NOT NULL
              AND bc.weight > 0
            ORDER BY bc.measured_at DESC, bc.id DESC
            LIMIT 1) AS latest_weight
    FROM joined j
  ),
  bmi_joined AS (
    SELECT w.*, public.manager_bmi_status(w.cheight, w.latest_weight) AS bmi_stat
    FROM weighted w
    WHERE (v_bmi IS NULL OR public.manager_bmi_status(w.cheight, w.latest_weight) = v_bmi)
  ),
  counted AS (
    SELECT j.*, count(*) OVER () AS total_cnt FROM bmi_joined j
  )
  SELECT c.rid, c.rname, c.cid, c.cphone, c.cgender, c.cbirth, c.cheight, c.cnt, c.last_at,
         coalesce((
           SELECT array_agg(DISTINCT coalesce(mp.nickname::text, '未命名'))
           FROM public.client_relations cr2
           JOIN caller_members cm2 ON cm2.manager_id = cr2.manager_id
           JOIN public.profiles mp ON mp.id = cr2.manager_id
           WHERE cr2.client_id = c.cid AND cr2.status = 'active'
         ), array[]::text[]),
         c.bmi_stat,
         c.total_cnt
  FROM counted c
  ORDER BY c.last_at DESC
  LIMIT v_limit OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.manager_weighing_people(text, date, date, text, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manager_weighing_people(text, date, date, text, text, integer, integer) TO authenticated;

-- 4) 商户端称重概览
CREATE OR REPLACE FUNCTION public.manager_weighing_overview()
RETURNS TABLE(today_count bigint, people_count bigint, total_count bigint, provider_counts jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_today_start timestamptz :=
    (((pg_catalog.now() AT TIME ZONE 'Asia/Shanghai')::date)::timestamp AT TIME ZONE 'Asia/Shanghai');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  RETURN QUERY
  WITH caller_members AS (
    SELECT s.manager_id FROM public.oem_scope_manager_ids() s
  ),
  authorized_records AS (
    SELECT hr.id AS rid
    FROM public.health_records hr
    JOIN public.client_relations cr ON cr.client_id = hr.user_id
    JOIN caller_members cm ON cm.manager_id = cr.manager_id
    WHERE cr.status = 'active'
      AND public.can_manager_view_client_category(hr.user_id, 'share_vitals')
      AND public.record_is_authorized(hr.id, cr.manager_id)
    GROUP BY hr.id
  ),
  scoped AS (
    SELECT bc.record_id, bc.measured_at, bc.provider_key
    FROM public.body_compositions bc
    WHERE (bc.oem_manager_id IN (SELECT cm.manager_id FROM caller_members cm)
            AND public.record_vitals_shared(bc.record_id))
       OR (bc.oem_manager_id IS NULL
            AND bc.record_id IN (SELECT ar.rid FROM authorized_records ar))
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

REVOKE ALL ON FUNCTION public.manager_weighing_overview() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manager_weighing_overview() TO authenticated;

-- 5) 单档案体成分明细（RETURNS TABLE，签名不变照计划 DROP 后重建）
DROP FUNCTION IF EXISTS public.manager_record_compositions(uuid, integer, integer);

CREATE FUNCTION public.manager_record_compositions(
  p_record_id uuid,
  p_limit integer DEFAULT 30,
  p_offset integer DEFAULT 0
)
RETURNS TABLE(
  id uuid,
  record_id uuid,
  measured_at timestamptz,
  provider_key text,
  origin text,
  weight numeric,
  heart_rate integer,
  heart_index numeric,
  bmi numeric,
  body_fat_percent numeric,
  water_percent numeric,
  skeletal_muscle_percent numeric,
  muscle_percent numeric,
  muscle_mass numeric,
  bone_mass numeric,
  lbm numeric,
  protein_percent numeric,
  subcutaneous_fat_percent numeric,
  visceral_fat_level numeric,
  body_age integer,
  body_shape text,
  bmr integer,
  muscle_storage_score numeric,
  health_score numeric,
  metrics_meta jsonb,
  missing_metrics jsonb,
  device_ref jsonb,
  notes text,
  oem_manager_id uuid,
  total_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 100);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF p_record_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH caller_members AS (
    SELECT s.manager_id FROM public.oem_scope_manager_ids() s
  ),
  authorized_records AS (
    SELECT hr.id AS rid
    FROM public.health_records hr
    JOIN public.client_relations cr ON cr.client_id = hr.user_id
    JOIN caller_members cm ON cm.manager_id = cr.manager_id
    WHERE cr.status = 'active'
      AND public.can_manager_view_client_category(hr.user_id, 'share_vitals')
      AND public.record_is_authorized(hr.id, cr.manager_id)
    GROUP BY hr.id
  ),
  visible AS (
    SELECT bc.*
    FROM public.body_compositions bc
    WHERE bc.record_id = p_record_id
      AND (
        (bc.oem_manager_id IN (SELECT cm.manager_id FROM caller_members cm)
          AND public.record_vitals_shared(bc.record_id))
        OR (bc.oem_manager_id IS NULL
          AND bc.record_id IN (SELECT ar.rid FROM authorized_records ar))
      )
  ),
  counted AS (
    SELECT v.*, count(*) OVER () AS total_rows
    FROM visible v
  )
  SELECT c.id, c.record_id, c.measured_at, c.provider_key, c.origin,
         c.weight, c.heart_rate, c.heart_index, c.bmi,
         c.body_fat_percent, c.water_percent, c.skeletal_muscle_percent,
         c.muscle_percent, c.muscle_mass, c.bone_mass, c.lbm,
         c.protein_percent, c.subcutaneous_fat_percent, c.visceral_fat_level,
         c.body_age, c.body_shape, c.bmr, c.muscle_storage_score,
         c.health_score, c.metrics_meta, c.missing_metrics,
         c.device_ref, c.notes, c.oem_manager_id, c.total_rows
  FROM counted c
  ORDER BY c.measured_at DESC, c.id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.manager_record_compositions(uuid, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manager_record_compositions(uuid, integer, integer) TO authenticated;

-- 6) 企业客户列表（RETURNS TABLE，10 参签名照最新版 DROP 后重建）
DROP FUNCTION IF EXISTS public.get_enterprise_clients_with_owner(integer, integer, text, uuid, date, date, date, date, date, text);

CREATE FUNCTION public.get_enterprise_clients_with_owner(
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0,
  p_search text DEFAULT NULL,
  p_owner_manager_id uuid DEFAULT NULL,
  p_created_from date DEFAULT NULL,
  p_created_to date DEFAULT NULL,
  p_reminder_from date DEFAULT NULL,
  p_reminder_to date DEFAULT NULL,
  p_last_contact_from date DEFAULT NULL,
  p_bmi_status text DEFAULT NULL
)
RETURNS TABLE(
  relation_id uuid,
  client_id uuid,
  status text,
  notes text,
  last_contact_at timestamptz,
  relation_created_at timestamptz,
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
  shop_first_entered_at timestamptz,
  store_name text,
  next_reminder_at timestamptz,
  reminder_status text,
  bmi_status text,
  total_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_limit int;
  v_offset int;
  v_search text;
  v_pattern text;
  v_today date;
  v_bmi text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF NOT public.is_enterprise_admin(v_uid) THEN
    RAISE EXCEPTION '仅企业管理员可访问' USING ERRCODE = '42501';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RETURN;
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);
  v_search := NULLIF(TRIM(COALESCE(p_search, '')), '');
  v_pattern := '%' || replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  v_today := (now() AT TIME ZONE 'Asia/Shanghai')::date;
  v_bmi := NULLIF(TRIM(COALESCE(p_bmi_status, '')), '');

  RETURN QUERY
  WITH members AS (
    SELECT v_root AS mid
    UNION
    SELECT p.id
    FROM public.profiles p
    WHERE p.parent_manager_id = v_root AND p.role = 'manager'
  ),
  caller_members AS (
    SELECT s.manager_id FROM public.oem_scope_manager_ids() s
  ),
  authorized_records AS (
    SELECT hr.id AS rid
    FROM public.health_records hr
    JOIN public.client_relations cr ON cr.client_id = hr.user_id
    JOIN caller_members cm ON cm.manager_id = cr.manager_id
    WHERE cr.status = 'active'
      AND public.can_manager_view_client_category(hr.user_id, 'share_vitals')
      AND public.record_is_authorized(hr.id, cr.manager_id)
    GROUP BY hr.id
  ),
  deduplicated_relations AS (
    SELECT DISTINCT ON (cr.client_id)
      cr.id AS relation_id,
      cr.client_id,
      cr.status::text AS status,
      cr.notes,
      cr.last_contact_at,
      cr.created_at AS relation_created_at,
      cr.manager_id AS owner_manager_id,
      cr.customer_name
    FROM public.client_relations cr
    WHERE cr.manager_id IN (SELECT mid FROM members)
      AND cr.status IS DISTINCT FROM 'deleted'
    ORDER BY
      cr.client_id,
      (cr.status = 'active') DESC,
      cr.updated_at DESC NULLS LAST,
      cr.created_at DESC,
      cr.id DESC
  ),
  relation_scoped AS (
    SELECT d.*
    FROM deduplicated_relations d
    WHERE (p_owner_manager_id IS NULL OR d.owner_manager_id = p_owner_manager_id)
      AND (
        v_search IS NULL
        OR EXISTS (
          SELECT 1 FROM public.profiles cp
          WHERE cp.id = d.client_id
            AND (cp.nickname ILIKE v_pattern ESCAPE '\'
                 OR cp.phone ILIKE v_pattern ESCAPE '\')
        )
        OR d.customer_name ILIKE v_pattern ESCAPE '\'
      )
      AND (p_created_from IS NULL OR (d.relation_created_at AT TIME ZONE 'Asia/Shanghai')::date >= p_created_from)
      AND (p_created_to IS NULL OR (d.relation_created_at AT TIME ZONE 'Asia/Shanghai')::date <= p_created_to)
      AND (p_last_contact_from IS NULL OR (d.last_contact_at AT TIME ZONE 'Asia/Shanghai')::date >= p_last_contact_from)
  ),
  with_reminder AS (
    SELECT
      c.*,
      rem.next_reminder_at
    FROM relation_scoped c
    LEFT JOIN LATERAL (
      SELECT fr.next_follow_up_at AS next_reminder_at
      FROM public.follow_up_records fr
      WHERE fr.client_relation_id = c.relation_id
        AND fr.reminder
        AND fr.next_follow_up_at IS NOT NULL
      ORDER BY fr.next_follow_up_at DESC
      LIMIT 1
    ) rem ON true
  ),
  filtered_rows AS (
    SELECT
      c.relation_id,
      c.client_id,
      c.status,
      c.notes,
      c.last_contact_at,
      c.relation_created_at,
      COALESCE(NULLIF(BTRIM(c.customer_name), ''), cp.nickname::text, '未命名客户') AS customer_name,
      cp.nickname::text,
      CASE
        WHEN COALESCE(cp.privacy_settings->>'show_phone', 'true') = 'false' THEN NULL
        WHEN public.is_admin(v_uid) THEN cp.phone::text
        WHEN public.is_enterprise_admin(v_uid) THEN cp.phone::text
        WHEN cp.phone ~ '^1[0-9]{10}$' THEN LEFT(cp.phone, 3) || '****' || RIGHT(cp.phone, 4)
        ELSE NULL
      END AS phone,
      cp.avatar_url,
      COALESCE(cp.privacy_settings, '{}'::jsonb) AS privacy_settings,
      c.owner_manager_id,
      op.nickname::text AS owner_manager_nickname,
      op.phone::text AS owner_manager_phone,
      COALESCE(op.sub_role, '')::text AS owner_sub_role,
      COALESCE(op.is_disabled, false) AS owner_is_disabled,
      sm.member_number AS shop_member_number,
      sm.first_entered_at AS shop_first_entered_at,
      st.name::text AS store_name,
      c.next_reminder_at,
      CASE
        WHEN c.next_reminder_at IS NULL THEN 'none'
        WHEN (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date < v_today THEN 'overdue'
        WHEN (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date = v_today THEN 'today'
        ELSE 'upcoming'
      END AS reminder_status,
      public.manager_bmi_status(oh.owner_height, ow.owner_weight) AS bmi_status
    FROM with_reminder c
    LEFT JOIN public.profiles cp ON cp.id = c.client_id
    LEFT JOIN public.profiles op ON op.id = c.owner_manager_id
    LEFT JOIN public.shop_members sm
      ON sm.root_manager_id = v_root AND sm.client_id = c.client_id
    LEFT JOIN public.user_store_bindings b
      ON b.user_id = c.client_id AND b.status = 'active'
    LEFT JOIN public.stores st
      ON st.id = b.store_id AND st.root_manager_id = v_root
    LEFT JOIN LATERAL (
      SELECT hr2.id AS owner_record_id, hr2.height AS owner_height
      FROM public.health_records hr2
      WHERE hr2.user_id = c.client_id
        AND public.can_manager_view_client_category(hr2.user_id, 'share_vitals')
      ORDER BY hr2.is_default DESC, hr2.created_at ASC, hr2.id ASC
      LIMIT 1
    ) oh ON true
    LEFT JOIN LATERAL (
      SELECT bc.weight AS owner_weight
      FROM public.body_compositions bc
      WHERE bc.record_id = oh.owner_record_id
        AND bc.weight IS NOT NULL
        AND bc.weight > 0
        AND (
          (bc.oem_manager_id IN (SELECT cm.manager_id FROM caller_members cm)
            AND public.record_vitals_shared(bc.record_id))
          OR (bc.oem_manager_id IS NULL
            AND bc.record_id IN (SELECT ar.rid FROM authorized_records ar))
        )
      ORDER BY bc.measured_at DESC, bc.id DESC
      LIMIT 1
    ) ow ON true
    WHERE (p_reminder_from IS NULL OR (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date >= p_reminder_from)
      AND (p_reminder_to IS NULL OR (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date <= p_reminder_to)
      AND (v_bmi IS NULL
           OR public.manager_bmi_status(oh.owner_height, ow.owner_weight) = v_bmi)
  ),
  counted_rows AS (
    SELECT f.*, COUNT(*) OVER() AS total_count
    FROM filtered_rows f
  )
  SELECT *
  FROM counted_rows
  ORDER BY relation_created_at DESC, relation_id DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid, date, date, date, date, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid, date, date, date, date, date, text) TO authenticated;