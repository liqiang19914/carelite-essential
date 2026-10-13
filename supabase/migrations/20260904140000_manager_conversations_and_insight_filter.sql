-- 1. 商户端对话列表：SECURITY DEFINER RPC，按 root_manager_id 隔离
CREATE OR REPLACE FUNCTION public.list_manager_conversations(
  p_limit int DEFAULT 200
)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  agent_id uuid,
  title text,
  status text,
  message_count int,
  created_at timestamptz,
  updated_at timestamptz,
  client_name text,
  agent_name text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_merchant_root(auth.uid()) THEN
    RETURN;
  END IF;
  v_root := auth.uid();

  RETURN QUERY
  SELECT
    c.id,
    c.user_id,
    c.agent_id,
    c.title,
    c.status,
    c.message_count,
    c.created_at,
    c.updated_at,
    p.nickname AS client_name,
    a.name AS agent_name
  FROM public.conversations c
  LEFT JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.ai_agents a ON a.id = c.agent_id
  WHERE c.owner_manager_id = v_root
    AND c.owner_manager_id IS NOT NULL
  ORDER BY c.updated_at DESC
  LIMIT p_limit;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_conversations(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_conversations(int) TO authenticated;

-- 2. 健康洞察 RPC：新增 p_user_id 参数，支持按特定用户筛选
CREATE OR REPLACE FUNCTION public.list_manager_health_insights(
  p_keyword text DEFAULT NULL,
  p_severity text DEFAULT NULL,
  p_user_id uuid DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 20
)
RETURNS TABLE (
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
  v_root uuid;
  v_limit int := GREATEST(1, LEAST(COALESCE(p_page_size, 20), 100));
  v_offset int := (GREATEST(1, p_page) - 1) * v_limit;
  v_keyword text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_merchant_root(auth.uid()) THEN
    RETURN;
  END IF;
  v_root := auth.uid();
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
    p.nickname AS client_nickname,
    COUNT(*) OVER () AS total_count
  FROM public.health_insights hi
  JOIN public.profiles p ON p.id = hi.user_id
  WHERE hi.root_manager_id = v_root
    AND (p_user_id IS NULL OR hi.user_id = p_user_id)
    AND (p_severity IS NULL OR p_severity = '' OR hi.severity = p_severity)
    AND (
      v_keyword IS NULL
      OR hi.title ILIKE '%' || v_keyword || '%'
      OR hi.content ILIKE '%' || v_keyword || '%'
      OR p.nickname ILIKE '%' || v_keyword || '%'
    )
  ORDER BY hi.analyzed_at DESC
  LIMIT v_limit OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_health_insights(text, text, uuid, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_health_insights(text, text, uuid, int, int) TO authenticated;
