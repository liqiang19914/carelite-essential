-- 根因：create_enterprise_employment RPC 在镜像就业状态时把
-- profiles.role 从 'user' 原地改成了 'manager'（SET role = CASE WHEN role='user' THEN 'manager' ELSE role END）。
--
-- 后果：
--   1. 消费者登录小程序 → 查 role='user' 匹配不上 → 分支 3 创建空壳 user profile；
--   2. 被升级的 profile 作为 manager，在客户列表 RPC 里被排除（我之前加的过滤）；
--   3. 多企业身份全毁——profile.role 是单值，二选一，无法同时是 manager 又是 user。
--
-- 修复：
--   A. create_enterprise_employment / 各种 leave/disable/leave RPC → 不再镜像 profiles.role
--      role 永远是原始身份（原生注册就是啥 role 就保持啥）；
--   B. 修复 389 个被错误升级的 profile：没有 managers 表行 = 被升上来的 = 改回 user；
--   C. 客户列表 RPC 去掉 role 过滤（client_relations 本身就是归属链）。

BEGIN;

-- ========================================================
-- A. 重写 create_enterprise_employment：去掉 role 镜像
-- ========================================================
CREATE OR REPLACE FUNCTION public.create_enterprise_employment(
  p_auth_user_id uuid,
  p_enterprise_id uuid,
  p_enterprise_role_id uuid DEFAULT NULL::uuid,
  p_supervisor_auth_user_id uuid DEFAULT NULL::uuid,
  p_sub_role text DEFAULT 'health_manager'::text,
  p_permissions jsonb DEFAULT '{}'::jsonb,
  p_make_primary boolean DEFAULT true,
  p_operator_auth_user_id uuid DEFAULT NULL::uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_existing_id uuid;
  v_employment_id uuid;
  v_effective_sub_role text := COALESCE(NULLIF(btrim(p_sub_role), ''), 'health_manager');
  v_permissions jsonb := COALESCE(p_permissions, '{}'::jsonb);
  v_operator uuid := COALESCE(p_operator_auth_user_id, auth.uid());
  v_make_primary boolean := COALESCE(p_make_primary, true);
  v_has_primary boolean;
  v_enterprise_name text;
  v_auth_phone text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.enterprises WHERE id = p_enterprise_id) THEN
    RAISE EXCEPTION '企业不存在' USING ERRCODE = 'P0001';
  END IF;

  IF p_enterprise_role_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.enterprise_roles
       WHERE id = p_enterprise_role_id AND enterprise_id = p_enterprise_id
     ) THEN
    RAISE EXCEPTION '所选角色不存在或不属于本企业' USING ERRCODE = 'P0001';
  END IF;

  -- 幂等：同企业已在职 → 返回现有行
  SELECT id INTO v_existing_id
  FROM public.enterprise_employments
  WHERE auth_user_id = p_auth_user_id
    AND enterprise_id = p_enterprise_id
    AND status IN ('active', 'disabled', 'pending')
  LIMIT 1;
  IF v_existing_id IS NOT NULL THEN
    RETURN v_existing_id;
  END IF;

  -- 坐席早退校验
  DECLARE
    v_seat_error text := public.check_employment_seat_limit(p_enterprise_id, p_auth_user_id);
  BEGIN
    IF v_seat_error IS NOT NULL THEN
      RAISE EXCEPTION '%', v_seat_error USING ERRCODE = 'P0001';
    END IF;
  END;

  INSERT INTO public.enterprise_employments (
    auth_user_id, enterprise_id, enterprise_role_id, supervisor_auth_user_id,
    sub_role, permissions, status, is_primary
  ) VALUES (
    p_auth_user_id, p_enterprise_id, p_enterprise_role_id, p_supervisor_auth_user_id,
    v_effective_sub_role, v_permissions, 'active', v_make_primary
  )
  RETURNING id INTO v_employment_id;

  -- 确保 primary 唯一
  SELECT EXISTS (
    SELECT 1 FROM public.enterprise_employments
    WHERE auth_user_id = p_auth_user_id AND is_primary AND id <> v_employment_id
  ) INTO v_has_primary;
  IF NOT v_has_primary THEN
    v_make_primary := true;
    UPDATE public.enterprise_employments
       SET is_primary = true, updated_at = now()
     WHERE id = v_employment_id;
  END IF;

  -- 主就业 → 镜像 profiles 旧列
  -- 【关键】不再镜像 role！role 是原始身份，由注册入口决定，不应被就业覆盖。
  IF v_make_primary THEN
    UPDATE public.enterprise_employments
       SET is_primary = false, updated_at = now()
     WHERE auth_user_id = p_auth_user_id AND id <> v_employment_id;

    UPDATE public.profiles
       SET parent_manager_id = p_supervisor_auth_user_id,
           enterprise_id = p_enterprise_id,
           enterprise_role_id = p_enterprise_role_id,
           sub_role = v_effective_sub_role,
           permissions = v_permissions,
           primary_employment_id = v_employment_id,
           updated_at = now()
     WHERE id = p_auth_user_id;
  END IF;

  IF v_operator IS NOT NULL THEN
    SELECT name INTO v_enterprise_name FROM public.enterprises WHERE id = p_enterprise_id;
    SELECT phone INTO v_auth_phone FROM public.profiles WHERE id = p_auth_user_id;
    INSERT INTO public.operation_logs (user_id, action, detail, module, metadata)
    VALUES (
      v_operator,
      '员工入职',
      format('新增员工（%s，%s）入职「%s」，角色：%s',
        COALESCE((SELECT nickname FROM public.profiles WHERE id = p_auth_user_id), ''),
        COALESCE(v_auth_phone, ''),
        COALESCE(v_enterprise_name, ''),
        v_effective_sub_role),
      '企业中心',
      jsonb_build_object(
        'employment_id', v_employment_id,
        'auth_user_id', p_auth_user_id,
        'enterprise_id', p_enterprise_id,
        'enterprise_role_id', p_enterprise_role_id,
        'sub_role', v_effective_sub_role,
        'mode', 'create_enterprise_employment'
      )
    );
  END IF;

  RETURN v_employment_id;
END;
$function$;

-- ========================================================
-- B. 修复历史数据：被就业镜像错误升级的 profile role 改回 'user'
--    判断标准：role='manager' + 有 enterprise_employments（说明是被升上来的）
--    + 没有 managers 表行（说明不是原生注册的商户管理员）
-- ========================================================
UPDATE public.profiles p
SET role = 'user',
    updated_at = now()
WHERE p.role = 'manager'
  AND NOT EXISTS (SELECT 1 FROM public.managers m WHERE m.id = p.id)    -- 原生 manager 有 managers 表行
  AND EXISTS (
    SELECT 1 FROM public.enterprise_employments ee
    WHERE ee.auth_user_id = p.id AND ee.status = 'active'
  );

-- ========================================================
-- C. 客户列表 RPC 去掉 role 过滤
--    client_relations 本身就是客户归属链，不该用 profile.role 硬挡
-- ========================================================
-- get_enterprise_clients_with_owner（企业管理员版）
CREATE OR REPLACE FUNCTION public.get_enterprise_clients_with_owner(
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0,
  p_search text DEFAULT NULL::text,
  p_owner_manager_id uuid DEFAULT NULL::uuid,
  p_created_from date DEFAULT NULL::date,
  p_created_to date DEFAULT NULL::date,
  p_reminder_from date DEFAULT NULL::date,
  p_reminder_to date DEFAULT NULL::date,
  p_last_contact_from date DEFAULT NULL::date,
  p_bmi_status text DEFAULT NULL::text
)
RETURNS TABLE(
  relation_id uuid, client_id uuid, status text, notes text, last_contact_at timestamptz,
  relation_created_at timestamptz, customer_name text, nickname text, phone text, avatar_url text,
  privacy_settings jsonb, owner_manager_id uuid, owner_manager_nickname text, owner_manager_phone text,
  owner_sub_role text, owner_is_disabled boolean, shop_member_number text, shop_first_entered_at timestamptz,
  store_name text, next_reminder_at timestamptz, reminder_status text, bmi_status text, total_count bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_limit int; v_offset int; v_search text; v_pattern text; v_today date; v_bmi text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION '未登录' USING ERRCODE = '28000'; END IF;
  IF NOT public.is_enterprise_admin(v_uid) THEN RAISE EXCEPTION '仅企业管理员可访问' USING ERRCODE = '42501'; END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN RETURN; END IF;

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
    SELECT p.id FROM public.profiles p
    WHERE p.parent_manager_id = v_root AND p.role = 'manager'
  ),
  caller_members AS (
    SELECT s.manager_id FROM public.oem_scope_manager_ids() s
  ),
  authorized_records AS (
    SELECT hr.id AS rid FROM public.health_records hr
    JOIN public.client_relations cr ON cr.client_id = hr.user_id
    JOIN caller_members cm ON cm.manager_id = cr.manager_id
    WHERE cr.status = 'active'
      AND public.can_manager_view_client_category(hr.user_id, 'share_vitals')
      AND public.record_is_authorized(hr.id, cr.manager_id)
    GROUP BY hr.id
  ),
  deduplicated_relations AS (
    -- 【关键】不再过滤 cp.role='user'：client_relations 本身就是归属链
    -- 不管 profile 原始身份是什么，只要被标记为客户就是客户
    SELECT DISTINCT ON (cr.client_id)
      cr.id AS relation_id, cr.client_id, cr.status::text AS status, cr.notes, cr.last_contact_at,
      cr.created_at AS relation_created_at, cr.manager_id AS owner_manager_id, cr.customer_name
    FROM public.client_relations cr
    WHERE cr.manager_id IN (SELECT mid FROM members)
      AND cr.status IS DISTINCT FROM 'deleted'
    ORDER BY cr.client_id, (cr.status = 'active') DESC, cr.updated_at DESC NULLS LAST, cr.created_at DESC, cr.id DESC
  ),
  relation_scoped AS (
    SELECT d.* FROM deduplicated_relations d
    WHERE (p_owner_manager_id IS NULL OR d.owner_manager_id = p_owner_manager_id)
      AND (
        v_search IS NULL
        OR EXISTS (SELECT 1 FROM public.profiles cp
                   WHERE cp.id = d.client_id
                     AND (cp.nickname ILIKE v_pattern ESCAPE '\' OR cp.phone ILIKE v_pattern ESCAPE '\'))
        OR d.customer_name ILIKE v_pattern ESCAPE '\'
      )
      AND (p_created_from IS NULL OR (d.relation_created_at AT TIME ZONE 'Asia/Shanghai')::date >= p_created_from)
      AND (p_created_to IS NULL OR (d.relation_created_at AT TIME ZONE 'Asia/Shanghai')::date <= p_created_to)
      AND (p_last_contact_from IS NULL OR (d.last_contact_at AT TIME ZONE 'Asia/Shanghai')::date >= p_last_contact_from)
  ),
  with_reminder AS (
    SELECT c.*, rem.next_reminder_at FROM relation_scoped c
    LEFT JOIN LATERAL (
      SELECT fr.next_follow_up_at AS next_reminder_at
      FROM public.follow_up_records fr
      WHERE fr.client_relation_id = c.relation_id AND fr.reminder AND fr.next_follow_up_at IS NOT NULL
      ORDER BY fr.next_follow_up_at DESC LIMIT 1
    ) rem ON true
  ),
  filtered_rows AS (
    SELECT
      c.relation_id, c.client_id, c.status, c.notes, c.last_contact_at, c.relation_created_at,
      COALESCE(NULLIF(BTRIM(c.customer_name), ''), cp.nickname::text, '未命名客户') AS customer_name,
      cp.nickname::text,
      CASE
        WHEN COALESCE(cp.privacy_settings->>'show_phone', 'true') = 'false' THEN NULL
        WHEN public.is_admin(v_uid) OR public.is_enterprise_admin(v_uid) THEN cp.phone::text
        WHEN cp.phone ~ '^1[0-9]{10}$' THEN LEFT(cp.phone, 3) || '****' || RIGHT(cp.phone, 4)
        ELSE NULL
      END AS phone,
      cp.avatar_url, COALESCE(cp.privacy_settings, '{}'::jsonb) AS privacy_settings,
      c.owner_manager_id,
      op.nickname::text AS owner_manager_nickname, op.phone::text AS owner_manager_phone,
      COALESCE(op.sub_role, '')::text AS owner_sub_role, COALESCE(op.is_disabled, false) AS owner_is_disabled,
      sm.member_number AS shop_member_number, sm.first_entered_at AS shop_first_entered_at,
      st.name::text AS store_name,
      c.next_reminder_at,
      CASE WHEN c.next_reminder_at IS NULL THEN 'none'
           WHEN (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date < v_today THEN 'overdue'
           WHEN (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date = v_today THEN 'today'
           ELSE 'upcoming' END AS reminder_status,
      public.manager_bmi_status(oh.owner_height, ow.owner_weight) AS bmi_status
    FROM with_reminder c
    LEFT JOIN public.profiles cp ON cp.id = c.client_id
    LEFT JOIN public.profiles op ON op.id = c.owner_manager_id
    LEFT JOIN public.shop_members sm ON sm.root_manager_id = v_root AND sm.client_id = c.client_id
    LEFT JOIN public.user_store_bindings b ON b.user_id = c.client_id AND b.status = 'active'
    LEFT JOIN public.stores st ON st.id = b.store_id AND st.root_manager_id = v_root
    LEFT JOIN LATERAL (
      SELECT hr2.id AS owner_record_id, hr2.height AS owner_height
      FROM public.health_records hr2
      WHERE hr2.user_id = c.client_id AND public.can_manager_view_client_category(hr2.user_id, 'share_vitals')
      ORDER BY hr2.is_default DESC, hr2.created_at ASC, hr2.id ASC LIMIT 1
    ) oh ON true
    LEFT JOIN LATERAL (
      SELECT bc.weight AS owner_weight FROM public.body_compositions bc
      WHERE bc.record_id = oh.owner_record_id AND bc.weight IS NOT NULL AND bc.weight > 0
        AND ((bc.oem_manager_id IN (SELECT cm.manager_id FROM caller_members cm) AND public.record_vitals_shared(bc.record_id))
             OR (bc.oem_manager_id IS NULL AND bc.record_id IN (SELECT ar.rid FROM authorized_records ar)))
      ORDER BY bc.measured_at DESC, bc.id DESC LIMIT 1
    ) ow ON true
    WHERE (p_reminder_from IS NULL OR (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date >= p_reminder_from)
      AND (p_reminder_to IS NULL OR (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date <= p_reminder_to)
      AND (v_bmi IS NULL OR public.manager_bmi_status(oh.owner_height, ow.owner_weight) = v_bmi)
  ),
  counted_rows AS (SELECT f.*, COUNT(*) OVER() AS total_count FROM filtered_rows f)
  SELECT * FROM counted_rows ORDER BY relation_created_at DESC, relation_id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$function$;

-- get_manager_clients（普通员工版）也去掉 role 过滤
CREATE OR REPLACE FUNCTION public.get_manager_clients(p_manager_id uuid, p_limit int DEFAULT 200)
RETURNS TABLE(
  relation_id uuid, client_id uuid, customer_name text, phone text, nickname text,
  avatar_url text, notes text, created_at timestamptz, last_contact_at timestamptz,
  status text, total_count bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  WITH base AS (
    SELECT
      cr.id AS relation_id,
      cr.client_id,
      COALESCE(cr.customer_name, p.nickname, '未命名客户') AS customer_name,
      CASE WHEN COALESCE(p.privacy_settings->>'show_phone','true') = 'false' THEN NULL ELSE p.phone END AS phone,
      p.nickname, p.avatar_url, cr.notes, cr.created_at, cr.last_contact_at, cr.status::text
    FROM client_relations cr
    JOIN profiles p ON p.id = cr.client_id       -- 不再过滤 role
    WHERE cr.manager_id = p_manager_id AND cr.status != 'deleted'
    ORDER BY cr.created_at DESC
  )
  SELECT b.*, COUNT(*) OVER() AS total_count FROM base b LIMIT LEAST(p_limit, 500);
END;
$function$;

COMMIT;
