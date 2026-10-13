CREATE OR REPLACE FUNCTION public.admin_list_health_insight_users(
  p_merchant_root uuid DEFAULT NULL,
  p_keyword text DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 20
)
RETURNS TABLE(
  id uuid,
  nickname text,
  phone text,
  last_analyzed_at timestamptz,
  insight_count bigint,
  critical_count bigint,
  total_count bigint
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_limit int;
  v_offset int;
  v_keyword text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅平台管理员可访问' USING ERRCODE = '42501';
  END IF;
  v_limit := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
  v_offset := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_keyword := NULLIF(BTRIM(COALESCE(p_keyword, '')), '');

  RETURN QUERY
  SELECT u.id,
         COALESCE(u.nickname, '')::text,
         COALESCE(u.phone, '')::text,
         agg.last_analyzed_at,
         COALESCE(agg.insight_count, 0)::bigint,
         COALESCE(agg.critical_count, 0)::bigint,
         COUNT(*) OVER() AS total_count
  FROM public.profiles u
  LEFT JOIN (
    SELECT hi.user_id,
           MAX(hi.analyzed_at) AS last_analyzed_at,
           COUNT(*) AS insight_count,
           COUNT(*) FILTER (WHERE hi.severity = 'critical') AS critical_count
    FROM public.health_insights hi
    GROUP BY hi.user_id
  ) agg ON agg.user_id = u.id
  WHERE u.role = 'user'
    AND (
      p_merchant_root IS NULL
      OR EXISTS (
        SELECT 1 FROM public.client_relations cr
        WHERE cr.client_id = u.id
          AND cr.status = 'active'
          AND public.get_enterprise_root_manager_id(cr.manager_id) = p_merchant_root
      )
    )
    AND (
      v_keyword IS NULL
      OR COALESCE(u.nickname, '') ILIKE '%' || v_keyword || '%'
      OR COALESCE(u.phone, '') ILIKE '%' || v_keyword || '%'
    )
  ORDER BY COALESCE(agg.critical_count, 0) DESC,
           COALESCE(agg.insight_count, 0) DESC,
           agg.last_analyzed_at DESC NULLS LAST,
           u.created_at DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_health_insight_users(uuid, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_health_insight_users(uuid, text, int, int) TO authenticated;