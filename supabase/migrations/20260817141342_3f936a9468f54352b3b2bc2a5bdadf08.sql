-- 企业健管师列表（含统计），供「健管师管理」页使用
CREATE OR REPLACE FUNCTION public.list_enterprise_health_managers()
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
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

  SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = v_uid;
  IF v_ent IS NULL THEN
    RETURN '[]'::json;
  END IF;
  SELECT owner_profile_id INTO v_owner FROM public.enterprises WHERE id = v_ent;

  SELECT COALESCE(json_agg(x ORDER BY x.sort, x.nickname), '[]'::json)
  INTO v_result
  FROM (
    SELECT
      p.id,
      p.nickname,
      p.phone,
      p.sub_role,
      p.is_disabled,
      COALESCE(r.name, '健康管理师') AS role_name,
      COALESCE(r.code, 'health_manager') AS role_code,
      (SELECT count(*)::int FROM public.client_relations cr WHERE cr.manager_id = p.id AND cr.status = 'active') AS client_count,
      (SELECT count(*)::int FROM public.manager_public_qa_sessions s WHERE s.manager_id = p.id) AS qa_count,
      (SELECT count(*)::int FROM public.manager_knowledge_documents d WHERE d.manager_id = p.id) AS knowledge_count,
      EXISTS (SELECT 1 FROM public.managers m WHERE m.id = p.id) AS has_agent,
      COALESCE((SELECT m.is_recommended FROM public.managers m WHERE m.id = p.id), false) AS is_recommended,
      COALESCE((SELECT m.knowledge_index_status FROM public.managers m WHERE m.id = p.id), 'none') AS knowledge_index_status,
      CASE WHEN v_owner = p.id THEN 0 ELSE 1 END AS sort
    FROM public.profiles p
    LEFT JOIN public.enterprise_roles r ON r.id = p.enterprise_role_id
    WHERE p.enterprise_id = v_ent AND p.role = 'manager'
  ) x;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_health_managers() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_enterprise_health_managers() TO authenticated;