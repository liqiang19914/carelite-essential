-- 修复 list_manager_health_insights 的列类型不匹配（和 conversations 同根因）
DROP FUNCTION IF EXISTS public.list_manager_health_insights(text, text, uuid, int, int);
CREATE OR REPLACE FUNCTION public.list_manager_health_insights(
  p_keyword text DEFAULT NULL,
  p_severity text DEFAULT NULL,
  p_user_id uuid DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 10
)
RETURNS TABLE(
  id uuid,
  user_id uuid,
  category varchar(50),
  title varchar(200),
  content text,
  severity varchar(20),
  source_type varchar(50),
  source_snippet text,
  analyzed_at timestamptz,
  client_nickname text,
  total_count bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 10), 1), 50);
  v_offset int := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_keyword text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_keyword := NULLIF(BTRIM(COALESCE(p_keyword, '')), '');

  RETURN QUERY
  SELECT
    hi.id,
    hi.user_id,
    hi.category,
    hi.title,
    hi.content,
    hi.severity,
    hi.source_type,
    hi.source_snippet,
    hi.analyzed_at,
    COALESCE(cp.nickname, '未命名')::text AS client_nickname,
    COUNT(*) OVER ()::bigint AS total_count
  FROM public.health_insights hi
  LEFT JOIN public.profiles cp ON cp.id = hi.user_id
  WHERE (p_severity IS NULL OR p_severity = '' OR hi.severity = p_severity)
    AND (p_user_id IS NULL OR hi.user_id = p_user_id)
    AND (
      v_keyword IS NULL
      OR hi.title ILIKE '%' || v_keyword || '%'
      OR hi.content ILIKE '%' || v_keyword || '%'
      OR COALESCE(cp.nickname, '') ILIKE '%' || v_keyword || '%'
    )
  ORDER BY hi.analyzed_at DESC
  LIMIT v_limit OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_health_insights(text, text, uuid, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_health_insights(text, text, uuid, int, int) TO authenticated;

-- list_manager_health_insights_clients 也可能有类似问题，一并检查
DROP FUNCTION IF EXISTS public.list_manager_health_insights_clients();
CREATE OR REPLACE FUNCTION public.list_manager_health_insights_clients()
RETURNS TABLE(
  id uuid,
  nickname text,
  phone text,
  insight_count bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  RETURN QUERY
  SELECT p.id,
         COALESCE(p.nickname, '')::text,
         COALESCE(p.phone, '')::text,
         COUNT(hi.id)::bigint
  FROM public.health_insights hi
  JOIN public.profiles p ON p.id = hi.user_id
  GROUP BY p.id, p.nickname, p.phone
  ORDER BY COUNT(hi.id) DESC
  LIMIT 200;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_health_insights_clients() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_health_insights_clients() TO authenticated;
