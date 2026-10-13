CREATE OR REPLACE FUNCTION public.list_manager_health_insights(
  p_keyword text DEFAULT NULL,
  p_severity text DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 10
)
RETURNS TABLE(
  id uuid,
  user_id uuid,
  category text,
  title text,
  content text,
  severity text,
  source_type text,
  source_snippet text,
  analyzed_at timestamptz,
  client_nickname text,
  total_count bigint
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_is_admin boolean;
  v_limit int;
  v_offset int;
  v_keyword text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.has_enterprise_permission('health_insights', v_uid) THEN
    RAISE EXCEPTION '你的角色未获授「查看健康洞察」，请联系超级管理员在企业中心勾选' USING ERRCODE = '42501';
  END IF;
  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  IF v_root IS NULL THEN
    RETURN;
  END IF;
  SELECT public.is_enterprise_admin(v_uid) INTO v_is_admin;
  v_limit := LEAST(GREATEST(COALESCE(p_page_size, 10), 1), 50);
  v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_keyword := NULLIF(BTRIM(COALESCE(p_keyword, '')), '');

  RETURN QUERY
  WITH visible AS (
    SELECT DISTINCT cr.client_id
    FROM public.client_relations cr
    WHERE cr.status = 'active'
      AND (v_is_admin OR cr.manager_id = v_uid)
      AND (cr.manager_id = v_uid
           OR cr.manager_id IN (
             SELECT p.id FROM public.profiles p
             WHERE p.parent_manager_id = v_root AND p.role = 'manager'
           )
           OR cr.manager_id = v_root)
      AND public.can_manager_view_client_data(cr.client_id, 'view_health_insights')
  ),
  filtered AS (
    SELECT hi.*, COALESCE(cp.nickname, '')::text AS client_nickname
    FROM public.health_insights hi
    JOIN visible v ON v.client_id = hi.user_id
    LEFT JOIN public.profiles cp ON cp.id = hi.user_id
    WHERE (p_severity IS NULL OR p_severity = '' OR hi.severity = p_severity)
      AND (
        v_keyword IS NULL
        OR hi.title ILIKE '%' || v_keyword || '%'
        OR hi.content ILIKE '%' || v_keyword || '%'
        OR COALESCE(cp.nickname, '') ILIKE '%' || v_keyword || '%'
      )
  )
  SELECT f.id,
         f.user_id,
         f.category::text,
         f.title::text,
         f.content,
         f.severity::text,
         f.source_type::text,
         f.source_snippet,
         f.analyzed_at,
         f.client_nickname,
         COUNT(*) OVER() AS total_count
  FROM filtered f
  ORDER BY f.analyzed_at DESC, f.id DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_health_insights(text, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_health_insights(text, text, int, int) TO authenticated;