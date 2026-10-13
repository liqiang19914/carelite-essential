CREATE OR REPLACE FUNCTION public.list_enterprise_agents()
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
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
  SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = v_uid;
  IF v_ent IS NULL THEN RETURN '[]'::json; END IF;

  SELECT COALESCE(json_agg(x ORDER BY x.nickname), '[]'::json)
  INTO v_result
  FROM (
    SELECT
      p.id AS manager_id,
      p.nickname,
      p.phone,
      COALESCE(r.name, '健康管理师') AS role_name,
      COALESCE(m.is_recommended, false) AS is_recommended,
      m.recommend_rank,
      (SELECT a.id FROM public.health_manager_agents a WHERE a.manager_id = p.id AND a.is_active LIMIT 1) AS active_agent_id,
      (SELECT a.name FROM public.health_manager_agents a WHERE a.manager_id = p.id AND a.is_active LIMIT 1) AS active_agent_name,
      (SELECT count(*)::int FROM public.health_manager_agents a WHERE a.manager_id = p.id AND a.status = 'draft') AS draft_count,
      (COALESCE(m.public_qa_enabled, false) AND COALESCE(m.knowledge_index_status, '') = 'ready') AS qa_ready
    FROM public.profiles p
    LEFT JOIN public.managers m ON m.id = p.id
    LEFT JOIN public.enterprise_roles r ON r.id = p.enterprise_role_id
    WHERE p.enterprise_id = v_ent AND p.role = 'manager'
  ) x;

  RETURN v_result;
END;
$function$;