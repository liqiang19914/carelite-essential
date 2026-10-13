-- ============================================================
-- Feature 460：owner 身份显示与权限兜底（幂等迁移）
-- 1) list_enterprise_health_managers / list_enterprise_agents 角色名 join 改
--    COALESCE(emp.enterprise_role_id, p.enterprise_role_id)，owner（无就业行）也能
--    显示「超级管理员」而不是回退「健康管理师」。
-- 2) get_my_permissions / has_enterprise_permission 的 owner 判据加
--    profiles.role='manager' AND parent_manager_id IS NULL 兜底，
--    企业行缺失时不降级为零权限。
-- ============================================================

CREATE OR REPLACE FUNCTION public.list_enterprise_health_managers(
  p_enterprise_id uuid DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ent uuid;
  v_owner uuid;
  v_result json;
BEGIN
  IF v_uid IS NULL THEN
    RETURN '[]'::json;
  END IF;
  IF NOT public.has_enterprise_permission('health_managers', v_uid) THEN
    RETURN '[]'::json;
  END IF;

  v_ent := COALESCE(
    p_enterprise_id,
    (SELECT ee.enterprise_id
       FROM public.enterprise_employments ee
      WHERE ee.auth_user_id = v_uid
        AND ee.status IN ('active', 'disabled', 'pending')
      ORDER BY ee.is_primary DESC, ee.created_at DESC
      LIMIT 1),
    (SELECT e.id FROM public.enterprises e WHERE e.owner_profile_id = v_uid LIMIT 1),
    (SELECT p.enterprise_id FROM public.profiles p WHERE p.id = v_uid)
  );
  IF v_ent IS NULL THEN
    RETURN '[]'::json;
  END IF;
  IF NOT public.is_enterprise_member(v_ent, v_uid) THEN
    RETURN '[]'::json;
  END IF;

  SELECT e.owner_profile_id INTO v_owner FROM public.enterprises e WHERE e.id = v_ent;

  SELECT COALESCE(json_agg(x ORDER BY x.sort, x.nickname), '[]'::json)
  INTO v_result
  FROM (
    SELECT
      p.id,
      p.nickname,
      p.phone,
      COALESCE(emp.sub_role, p.sub_role) AS sub_role,
      p.is_disabled,
      emp.status,
      COALESCE(r.name, '健康管理师') AS role_name,
      COALESCE(r.code, 'health_manager') AS role_code,
      (SELECT count(*)::int FROM public.client_relations cr WHERE cr.manager_id = p.id AND cr.status = 'active') AS client_count,
      (SELECT count(*)::int FROM public.manager_public_qa_sessions s WHERE s.manager_id = p.id) AS qa_count,
      (SELECT count(*)::int FROM public.manager_knowledge_documents d WHERE d.manager_id = p.id) AS knowledge_count,
      EXISTS (SELECT 1 FROM public.managers m WHERE m.id = p.id) AS has_agent,
      COALESCE((SELECT m.is_recommended FROM public.managers m WHERE m.id = p.id), false) AS is_recommended,
      COALESCE((SELECT m.knowledge_index_status FROM public.managers m WHERE m.id = p.id), 'none') AS knowledge_index_status,
      CASE WHEN v_owner = p.id THEN 0 ELSE 1 END AS sort
    FROM (
      SELECT e2.owner_profile_id AS uid FROM public.enterprises e2
       WHERE e2.id = v_ent AND e2.owner_profile_id IS NOT NULL
      UNION
      SELECT ee.auth_user_id FROM public.enterprise_employments ee
       WHERE ee.enterprise_id = v_ent
    ) mem
    JOIN public.profiles p ON p.id = mem.uid AND p.role = 'manager'
    LEFT JOIN LATERAL (
      SELECT ee.status, ee.sub_role, ee.enterprise_role_id
      FROM public.enterprise_employments ee
      WHERE ee.auth_user_id = mem.uid AND ee.enterprise_id = v_ent
      ORDER BY CASE ee.status WHEN 'left' THEN 1 ELSE 0 END, ee.created_at DESC
      LIMIT 1
    ) emp ON true
    LEFT JOIN public.enterprise_roles r ON r.id = COALESCE(emp.enterprise_role_id, p.enterprise_role_id)
  ) x;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_health_managers(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_enterprise_health_managers(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_enterprise_health_managers(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.list_enterprise_agents(
  p_enterprise_id uuid DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ent uuid;
  v_result json;
BEGIN
  IF v_uid IS NULL THEN RETURN '[]'::json; END IF;
  IF NOT public.has_enterprise_permission('agents', v_uid) THEN
    RETURN '[]'::json;
  END IF;

  v_ent := COALESCE(
    p_enterprise_id,
    (SELECT ee.enterprise_id
       FROM public.enterprise_employments ee
      WHERE ee.auth_user_id = v_uid
        AND ee.status IN ('active', 'disabled', 'pending')
      ORDER BY ee.is_primary DESC, ee.created_at DESC
      LIMIT 1),
    (SELECT e.id FROM public.enterprises e WHERE e.owner_profile_id = v_uid LIMIT 1),
    (SELECT p.enterprise_id FROM public.profiles p WHERE p.id = v_uid)
  );
  IF v_ent IS NULL THEN RETURN '[]'::json; END IF;
  IF NOT public.is_enterprise_member(v_ent, v_uid) THEN
    RETURN '[]'::json;
  END IF;

  SELECT COALESCE(json_agg(x ORDER BY x.nickname), '[]'::json)
  INTO v_result
  FROM (
    SELECT
      p.id AS manager_id,
      p.nickname,
      p.phone,
      COALESCE(r.name, '健康管理师') AS role_name,
      emp.status,
      COALESCE(m.is_recommended, false) AS is_recommended,
      m.recommend_rank,
      COALESCE(m.is_public_visible, true) AS is_public_visible,
      (SELECT a.id FROM public.health_manager_agents a WHERE a.manager_id = p.id AND a.is_active LIMIT 1) AS active_agent_id,
      (SELECT a.name FROM public.health_manager_agents a WHERE a.manager_id = p.id AND a.is_active LIMIT 1) AS active_agent_name,
      (SELECT count(*)::int FROM public.health_manager_agents a WHERE a.manager_id = p.id AND a.status = 'draft') AS draft_count,
      (COALESCE(m.public_qa_enabled, false) AND COALESCE(m.knowledge_index_status, '') = 'ready') AS qa_ready
    FROM (
      SELECT e2.owner_profile_id AS uid FROM public.enterprises e2
       WHERE e2.id = v_ent AND e2.owner_profile_id IS NOT NULL
      UNION
      SELECT ee.auth_user_id FROM public.enterprise_employments ee
       WHERE ee.enterprise_id = v_ent
    ) mem
    JOIN public.profiles p ON p.id = mem.uid AND p.role = 'manager'
    LEFT JOIN LATERAL (
      SELECT ee.status, ee.sub_role, ee.enterprise_role_id
      FROM public.enterprise_employments ee
      WHERE ee.auth_user_id = mem.uid AND ee.enterprise_id = v_ent
      ORDER BY CASE ee.status WHEN 'left' THEN 1 ELSE 0 END, ee.created_at DESC
      LIMIT 1
    ) emp ON true
    LEFT JOIN public.managers m ON m.id = p.id
    LEFT JOIN public.enterprise_roles r ON r.id = COALESCE(emp.enterprise_role_id, p.enterprise_role_id)
  ) x;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_agents(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_enterprise_agents(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_enterprise_agents(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_my_permissions(
  p_enterprise_id uuid DEFAULT NULL
)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM public.enterprises e WHERE e.owner_profile_id = auth.uid())
      OR EXISTS (
        SELECT 1 FROM public.profiles p
        WHERE p.id = auth.uid() AND p.role = 'manager' AND p.parent_manager_id IS NULL
      )
    THEN (SELECT COALESCE(array_agg(code ORDER BY code), ARRAY[]::text[]) FROM public.permission_definitions)
    ELSE COALESCE(
      (
        SELECT array_agg(rp.permission_code ORDER BY rp.permission_code)
        FROM public.enterprise_role_permissions rp
        WHERE rp.role_id = (
          SELECT ee.enterprise_role_id
          FROM public.enterprise_employments ee
          WHERE ee.auth_user_id = auth.uid()
            AND ee.status IN ('active', 'pending')
            AND ee.enterprise_role_id IS NOT NULL
            AND (p_enterprise_id IS NULL OR ee.enterprise_id = p_enterprise_id)
          ORDER BY ee.is_primary DESC, ee.created_at DESC
          LIMIT 1
        )
      ),
      (
        SELECT array_agg(rp.permission_code ORDER BY rp.permission_code)
        FROM public.profiles p
        JOIN public.enterprise_role_permissions rp ON rp.role_id = p.enterprise_role_id
        WHERE p.id = auth.uid()
      ),
      ARRAY[]::text[]
    )
  END;
$function$;

REVOKE ALL ON FUNCTION public.get_my_permissions(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_permissions(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_permissions(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.has_enterprise_permission(p_permission_code text, p_uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    EXISTS (SELECT 1 FROM public.enterprises e WHERE e.owner_profile_id = p_uid)
    OR EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = p_uid AND p.role = 'manager' AND p.parent_manager_id IS NULL
    )
    OR EXISTS (
      SELECT 1
      FROM public.enterprise_employments ee
      JOIN public.enterprise_role_permissions rp ON rp.role_id = ee.enterprise_role_id
      WHERE ee.auth_user_id = p_uid
        AND ee.status IN ('active', 'pending')
        AND rp.permission_code = p_permission_code
    )
    OR (
      NOT EXISTS (
        SELECT 1 FROM public.enterprise_employments
        WHERE auth_user_id = p_uid AND status IN ('active', 'disabled', 'pending')
      )
      AND EXISTS (
        SELECT 1
        FROM public.profiles p
        JOIN public.enterprise_role_permissions rp ON rp.role_id = p.enterprise_role_id
        WHERE p.id = p_uid AND rp.permission_code = p_permission_code
      )
    );
$function$;

REVOKE ALL ON FUNCTION public.has_enterprise_permission(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.has_enterprise_permission(text, uuid) TO authenticated;