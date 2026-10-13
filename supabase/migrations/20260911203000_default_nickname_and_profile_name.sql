-- 新用户默认昵称稳定收敛为「用户+手机号后四位」；客户列表加「档案姓名」只读 lookup 列
--
-- 根因：handle_new_user 用 SUBSTR(NEW.phone, -4) 取后四位，但 PostgreSQL 的
-- substr(text, 负数起点) 会返回整串（不是最后四位），GoTrue 存的 phone 是
-- 无 + 的 86+手机号，于是 metadata 无昵称的 SMS/一键手机号注册新用户被命名成
-- 「用户86+完整手机号」。8/22 只洗过存量数据、没修函数，新用户继续漏全名。
-- 同时三个客户列表 RPC 增加 profile_name：按本人健康档案（health_records）
-- 只读 lookup，直连账号优先、同手机号账号兜底；不写任何业务数据。
-- 因 RETURNS TABLE 加列，OR REPLACE 无法改返回结构，先 DROP 再按原 ACL 重授权。

DROP FUNCTION IF EXISTS public.get_enterprise_clients_with_owner(int4,int4,text,uuid,date,date,date,date,date,text);

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_meta_nick text := NEW.raw_user_meta_data->>'nickname';
  v_digits text := regexp_replace(COALESCE(NEW.phone, ''), '\D', '', 'g');
  v_nickname text;
BEGIN
  -- metadata 里的昵称只有「非默认形态」才采信：历史有链路写入「用户86+完整手机号」，
  -- 一律收敛为「用户+手机号后四位」。注意 PG substr(text, 负数) 会返回整串，不能用。
  IF v_meta_nick IS NOT NULL
     AND btrim(v_meta_nick) <> ''
     AND btrim(v_meta_nick) !~ '^用户\+?[0-9]{7,}$' THEN
    v_nickname := v_meta_nick;
  ELSIF length(v_digits) >= 4 THEN
    v_nickname := '用户' || right(v_digits, 4);
  ELSE
    v_nickname := COALESCE(NULLIF(btrim(v_meta_nick), ''), '微信用户');
  END IF;

  INSERT INTO public.profiles (id, phone, nickname)
  VALUES (NEW.id, NEW.phone, v_nickname)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$function$;

UPDATE public.profiles
SET nickname = '用户' || right(regexp_replace(nickname, '\D', '', 'g'), 4),
    updated_at = now()
WHERE nickname ~ '^用户\+?[0-9]{7,}$';

CREATE OR REPLACE FUNCTION public.get_enterprise_clients_with_owner(p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_search text DEFAULT NULL::text, p_owner_manager_id uuid DEFAULT NULL::uuid, p_created_from date DEFAULT NULL::date, p_created_to date DEFAULT NULL::date, p_reminder_from date DEFAULT NULL::date, p_reminder_to date DEFAULT NULL::date, p_last_contact_from date DEFAULT NULL::date, p_bmi_status text DEFAULT NULL::text)
 RETURNS TABLE(relation_id uuid, client_id uuid, status text, notes text, last_contact_at timestamp with time zone, relation_created_at timestamp with time zone, customer_name text, nickname text, phone text, avatar_url text, privacy_settings jsonb, owner_manager_id uuid, owner_manager_nickname text, owner_manager_phone text, owner_sub_role text, owner_is_disabled boolean, shop_member_number text, shop_first_entered_at timestamp with time zone, store_name text, next_reminder_at timestamp with time zone, reminder_status text, bmi_status text, profile_name text, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
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
      public.manager_bmi_status(oh.owner_height, ow.owner_weight) AS bmi_status,
      COALESCE(
        (SELECT phr.name FROM public.health_records phr
          WHERE phr.user_id = c.client_id
            AND phr.relationship IN ('本人','self')
            AND btrim(COALESCE(phr.name,'')) <> ''
            AND phr.name NOT IN ('未命名客户','微信用户')
            AND phr.name NOT LIKE '用户%'
          ORDER BY phr.is_default DESC NULLS LAST, phr.updated_at DESC, phr.created_at DESC
          LIMIT 1),
        (SELECT phr.name FROM public.health_records phr
          JOIN public.profiles hp ON hp.id = phr.user_id
          WHERE btrim(COALESCE(cp.phone,'')) <> ''
            AND hp.phone = cp.phone AND hp.id <> c.client_id
            AND phr.relationship IN ('本人','self')
            AND btrim(COALESCE(phr.name,'')) <> ''
            AND phr.name NOT IN ('未命名客户','微信用户')
            AND phr.name NOT LIKE '用户%'
          ORDER BY phr.is_default DESC NULLS LAST, phr.updated_at DESC, phr.created_at DESC
          LIMIT 1)
      )::text AS profile_name
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

DROP FUNCTION IF EXISTS public.get_manager_clients(uuid);
CREATE OR REPLACE FUNCTION public.get_manager_clients(p_manager_id uuid)
 RETURNS TABLE(relation_id uuid, client_id uuid, status text, notes text, last_contact_at timestamp with time zone, relation_created_at timestamp with time zone, customer_name text, nickname text, phone text, avatar_url text, privacy_settings jsonb, shop_member_number text, shop_first_entered_at timestamp with time zone, store_name text, next_reminder_at timestamp with time zone, reminder_status text, bmi_status text, profile_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH authorized AS (
    SELECT 1
    WHERE auth.uid() = p_manager_id
       OR is_admin(auth.uid())
       OR is_enterprise_member_for_admin(p_manager_id, auth.uid())
  ),
  root_id AS (
    SELECT public.get_enterprise_root_manager_id(p_manager_id) AS rid
  ),
  deduplicated AS (
    SELECT DISTINCT ON (cr.client_id)
      cr.id AS relation_id,
      cr.client_id,
      cr.status::text,
      cr.notes,
      cr.last_contact_at,
      cr.created_at AS relation_created_at,
      cr.customer_name
    FROM client_relations cr
    WHERE cr.manager_id = p_manager_id
      AND cr.status IS DISTINCT FROM 'deleted'
    ORDER BY
      cr.client_id,
      (cr.status = 'active') DESC,
      cr.updated_at DESC NULLS LAST,
      cr.created_at DESC,
      cr.id DESC
  ),
  with_reminder AS (
    SELECT c.*, rem.next_reminder_at
    FROM deduplicated c
    LEFT JOIN LATERAL (
      SELECT fr.next_follow_up_at AS next_reminder_at
      FROM follow_up_records fr
      WHERE fr.client_relation_id = c.relation_id
        AND fr.reminder
        AND fr.next_follow_up_at IS NOT NULL
      ORDER BY fr.next_follow_up_at DESC
      LIMIT 1
    ) rem ON true
  )
  SELECT
    c.relation_id,
    c.client_id,
    c.status,
    c.notes,
    c.last_contact_at,
    c.relation_created_at,
    COALESCE(NULLIF(BTRIM(c.customer_name), ''), p.nickname::text, '未命名客户') AS customer_name,
    p.nickname::text,
    CASE
      WHEN COALESCE(p.privacy_settings->>'show_phone', 'true') = 'false' THEN NULL
      WHEN public.is_admin(auth.uid()) THEN p.phone::text
      WHEN EXISTS (
        SELECT 1 FROM public.profiles caller
        WHERE caller.id = auth.uid()
          AND caller.role = 'manager'
          AND COALESCE(caller.is_disabled, false) = false
          AND (caller.parent_manager_id IS NULL OR caller.sub_role = 'admin')
          AND public.get_enterprise_root_manager_id(caller.id) = (SELECT rid FROM root_id)
      ) THEN p.phone::text
      WHEN p.phone ~ '^1[0-9]{10}$' THEN LEFT(p.phone, 3) || '****' || RIGHT(p.phone, 4)
      ELSE NULL
    END AS phone,
    p.avatar_url,
    COALESCE(p.privacy_settings, '{}'::jsonb) AS privacy_settings,
    sm.member_number AS shop_member_number,
    sm.first_entered_at AS shop_first_entered_at,
    st.name::text AS store_name,
    c.next_reminder_at,
    CASE
      WHEN c.next_reminder_at IS NULL THEN 'none'
      WHEN (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date < ((now() AT TIME ZONE 'Asia/Shanghai')::date) THEN 'overdue'
      WHEN (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date = ((now() AT TIME ZONE 'Asia/Shanghai')::date) THEN 'today'
      ELSE 'upcoming'
    END AS reminder_status,
    public.manager_bmi_status(oh.owner_height, ow.owner_weight) AS bmi_status,
    COALESCE(
      (SELECT phr.name FROM public.health_records phr
        WHERE phr.user_id = c.client_id
          AND phr.relationship IN ('本人','self')
          AND btrim(COALESCE(phr.name,'')) <> ''
          AND phr.name NOT IN ('未命名客户','微信用户')
          AND phr.name NOT LIKE '用户%'
        ORDER BY phr.is_default DESC NULLS LAST, phr.updated_at DESC, phr.created_at DESC
        LIMIT 1),
      (SELECT phr.name FROM public.health_records phr
        JOIN public.profiles hp ON hp.id = phr.user_id
        WHERE btrim(COALESCE(p.phone,'')) <> ''
          AND hp.phone = p.phone AND hp.id <> c.client_id
          AND phr.relationship IN ('本人','self')
          AND btrim(COALESCE(phr.name,'')) <> ''
          AND phr.name NOT IN ('未命名客户','微信用户')
          AND phr.name NOT LIKE '用户%'
        ORDER BY phr.is_default DESC NULLS LAST, phr.updated_at DESC, phr.created_at DESC
        LIMIT 1)
    )::text AS profile_name
  FROM with_reminder c
  CROSS JOIN authorized
  LEFT JOIN profiles p ON p.id = c.client_id
  LEFT JOIN shop_members sm
    ON sm.root_manager_id = (SELECT rid FROM root_id) AND sm.client_id = c.client_id
  LEFT JOIN user_store_bindings b
    ON b.user_id = c.client_id AND b.status = 'active'
  LEFT JOIN stores st
    ON st.id = b.store_id AND st.root_manager_id = (SELECT rid FROM root_id)
  LEFT JOIN LATERAL (
    SELECT hr2.id AS owner_record_id, hr2.height AS owner_height
    FROM health_records hr2
    WHERE hr2.user_id = c.client_id
    ORDER BY hr2.is_default DESC, hr2.created_at ASC, hr2.id ASC
    LIMIT 1
  ) oh ON true
  LEFT JOIN LATERAL (
    SELECT bc.weight AS owner_weight
    FROM body_compositions bc
    WHERE bc.record_id = oh.owner_record_id
      AND bc.weight IS NOT NULL
      AND bc.weight > 0
    ORDER BY bc.measured_at DESC, bc.id DESC
    LIMIT 1
  ) ow ON true
  ORDER BY c.relation_created_at DESC;
$function$;

DROP FUNCTION IF EXISTS public.get_manager_clients(uuid, integer);
CREATE OR REPLACE FUNCTION public.get_manager_clients(p_manager_id uuid, p_limit integer)
 RETURNS TABLE(relation_id uuid, client_id uuid, customer_name text, phone text, nickname text, avatar_url text, notes text, created_at timestamp with time zone, last_contact_at timestamp with time zone, status text, profile_name text, total_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY WITH base AS (
    SELECT cr.id AS relation_id, cr.client_id,
      COALESCE(cr.customer_name, p.nickname, '未命名客户') AS customer_name,
      CASE WHEN COALESCE(p.privacy_settings->>'show_phone','true') = 'false' THEN NULL ELSE p.phone END AS phone,
      p.nickname, p.avatar_url, cr.notes, cr.created_at, cr.last_contact_at, cr.status::text,
      COALESCE(
        (SELECT phr.name FROM public.health_records phr
          WHERE phr.user_id = cr.client_id
            AND phr.relationship IN ('本人','self')
            AND btrim(COALESCE(phr.name,'')) <> ''
            AND phr.name NOT IN ('未命名客户','微信用户')
            AND phr.name NOT LIKE '用户%'
          ORDER BY phr.is_default DESC NULLS LAST, phr.updated_at DESC, phr.created_at DESC
          LIMIT 1),
        (SELECT phr.name FROM public.health_records phr
          JOIN public.profiles hp ON hp.id = phr.user_id
          WHERE btrim(COALESCE(p.phone,'')) <> ''
            AND hp.phone = p.phone AND hp.id <> cr.client_id
            AND phr.relationship IN ('本人','self')
            AND btrim(COALESCE(phr.name,'')) <> ''
            AND phr.name NOT IN ('未命名客户','微信用户')
            AND phr.name NOT LIKE '用户%'
          ORDER BY phr.is_default DESC NULLS LAST, phr.updated_at DESC, phr.created_at DESC
          LIMIT 1)
      ) AS profile_name
    FROM client_relations cr
    JOIN profiles p ON p.id = cr.client_id AND p.role = 'user'
    WHERE cr.manager_id = p_manager_id AND cr.status != 'deleted'
    ORDER BY cr.created_at DESC
  )
  SELECT b.relation_id, b.client_id, b.customer_name::text, b.phone::text,
         b.nickname::text, b.avatar_url::text, b.notes::text,
         b.created_at, b.last_contact_at, b.status, b.profile_name::text,
         COUNT(*) OVER() AS total_count
  FROM base b LIMIT LEAST(p_limit, 500);
END;
$function$;



REVOKE ALL ON FUNCTION public.get_enterprise_clients_with_owner(int4,int4,text,uuid,date,date,date,date,date,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_enterprise_clients_with_owner(int4,int4,text,uuid,date,date,date,date,date,text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.get_manager_clients(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_manager_clients(uuid) TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.get_manager_clients(uuid, integer) TO PUBLIC, anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
