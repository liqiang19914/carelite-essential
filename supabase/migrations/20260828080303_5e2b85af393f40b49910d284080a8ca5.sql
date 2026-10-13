-- ============ 搜索按字面匹配：转义 ILIKE 通配符（% _ \），% 不再匹配全部 ============

-- 1) 回收站列表：搜索模式转义后按字面匹配
CREATE OR REPLACE FUNCTION public.get_deleted_clients(
  p_search text DEFAULT '',
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_search text := NULLIF(btrim(COALESCE(p_search, '')), '');
  v_pattern text;
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
  v_offset int := GREATEST(COALESCE(p_offset, 0), 0);
  v_items jsonb;
  v_total bigint;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RAISE EXCEPTION '仅企业超级管理员可查看回收站' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  v_pattern := '%' || replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_') || '%';

  SELECT COUNT(*)
  INTO v_total
  FROM public.client_relations cr
  LEFT JOIN public.profiles p ON p.id = cr.client_id
  WHERE cr.status = 'deleted'
    AND (
      cr.root_manager_id = v_root
      OR (cr.root_manager_id IS NULL AND cr.manager_id IN (
        SELECT v_root AS mid
        UNION
        SELECT mp.id FROM public.profiles mp
        WHERE mp.parent_manager_id = v_root AND mp.role = 'manager'
      ))
    )
    AND (v_search IS NULL
         OR COALESCE(NULLIF(btrim(cr.customer_name), ''), p.nickname, '') ILIKE v_pattern ESCAPE '\'
         OR p.nickname ILIKE v_pattern ESCAPE '\'
         OR p.phone ILIKE v_pattern ESCAPE '\');

  SELECT COALESCE(jsonb_agg(x.item ORDER BY x.deleted_at DESC, x.rid DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      jsonb_build_object(
        'relation_id', cr.id,
        'client_id', cr.client_id,
        'customer_name', COALESCE(NULLIF(btrim(cr.customer_name), ''), p.nickname, '未命名客户'),
        'phone', CASE
          WHEN COALESCE(p.privacy_settings->>'show_phone', 'true') = 'false' THEN NULL
          WHEN p.phone ~ '^1[0-9]{10}$' THEN LEFT(p.phone, 3) || '****' || RIGHT(p.phone, 4)
          ELSE NULL
        END,
        'deleted_at', cr.updated_at,
        'owner_manager_nickname', COALESCE(NULLIF(btrim(op.nickname), ''), '未命名员工')
      ) AS item,
      cr.updated_at AS deleted_at,
      cr.id AS rid
    FROM public.client_relations cr
    LEFT JOIN public.profiles p ON p.id = cr.client_id
    LEFT JOIN public.profiles op ON op.id = cr.manager_id
    WHERE cr.status = 'deleted'
      AND (
        cr.root_manager_id = v_root
        OR (cr.root_manager_id IS NULL AND cr.manager_id IN (
          SELECT v_root AS mid
          UNION
          SELECT mp.id FROM public.profiles mp
          WHERE mp.parent_manager_id = v_root AND mp.role = 'manager'
        ))
      )
      AND (v_search IS NULL
           OR COALESCE(NULLIF(btrim(cr.customer_name), ''), p.nickname, '') ILIKE v_pattern ESCAPE '\'
           OR p.nickname ILIKE v_pattern ESCAPE '\'
           OR p.phone ILIKE v_pattern ESCAPE '\')
    ORDER BY cr.updated_at DESC, cr.id DESC
    LIMIT v_limit
    OFFSET v_offset
  ) x;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_deleted_clients(text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_deleted_clients(text, integer, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_deleted_clients(text, integer, integer) TO authenticated;

-- 2) 企业客户列表：搜索模式同样按字面匹配
CREATE OR REPLACE FUNCTION public.get_enterprise_clients_with_owner(
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

REVOKE ALL ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid, date, date, date, date, date, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid, date, date, date, date, date, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid, date, date, date, date, date, text) TO authenticated;