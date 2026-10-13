-- 紧急修复：放宽 conversations 和 health_insights 权限——先展示所有数据让用户看到
-- 待 client_relations/owner_manager_id 数据回填后再加回来

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
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;

  -- 不过滤，先返回所有有 owner_manager_id 的（有明确归属）
  RETURN QUERY
  SELECT
    c.id, c.user_id, c.agent_id, c.title, c.status,
    COALESCE(c.message_count, 0)::int, c.created_at, c.updated_at,
    COALESCE(p.nickname, '未命名') AS client_name,
    COALESCE(a.name, 'AI 助手') AS agent_name
  FROM public.conversations c
  LEFT JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.ai_agents a ON a.id = c.agent_id
  ORDER BY c.updated_at DESC
  LIMIT p_limit;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_conversations(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_conversations(int) TO authenticated;

-- 健康洞察客户列表：先不过滤 root_manager_id
CREATE OR REPLACE FUNCTION public.list_manager_health_insights_clients()
RETURNS TABLE(
  id uuid,
  nickname text,
  phone text,
  insight_count bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;

  RETURN QUERY
  SELECT p.id, COALESCE(p.nickname, ''), COALESCE(p.phone, ''),
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

-- list_manager_health_insights 也临时放宽：跳过 client_relations + root_manager_id
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
