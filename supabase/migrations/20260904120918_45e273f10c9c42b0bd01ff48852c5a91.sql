-- 修复 list_enterprise_agents：LATERAL 需带出 enterprise_role_id 供角色名 join
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
    LEFT JOIN public.enterprise_roles r ON r.id = emp.enterprise_role_id
  ) x;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_agents(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_enterprise_agents(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_enterprise_agents(uuid) TO authenticated;