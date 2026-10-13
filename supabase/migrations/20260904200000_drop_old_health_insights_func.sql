-- 解决 list_manager_health_insights 函数重载冲突：DROP 旧的 4 参数版本
DROP FUNCTION IF EXISTS public.list_manager_health_insights(text, text, int, int);

-- 确认只保留 5 参数版本
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
    COALESCE(cp.nickname, '未命名') AS client_nickname,
    COUNT(*) OVER () AS total_count
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
