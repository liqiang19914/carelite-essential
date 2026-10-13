-- 简化版 list_manager_conversations：直接用 owner_manager_id = auth.get_enterprise_root_manager_id 过滤
-- 跳过 client_relations（因为 root manager 自身可能不在 client_relations 里）
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
  v_root uuid;
  v_is_admin boolean;
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;

  -- 平台 admin 看全部
  SELECT role = 'admin' INTO v_is_admin FROM public.profiles WHERE id = v_uid;

  IF v_is_admin THEN
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
    RETURN;
  END IF;

  -- 企业/商户：取 enterprise root manager id
  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  IF v_root IS NULL THEN RETURN; END IF;

  -- 直接按 owner_manager_id = v_root 过滤（ai-chat EF 一定会写这个字段）
  RETURN QUERY
  SELECT
    c.id, c.user_id, c.agent_id, c.title, c.status,
    COALESCE(c.message_count, 0)::int, c.created_at, c.updated_at,
    COALESCE(p.nickname, '未命名') AS client_name,
    COALESCE(a.name, 'AI 助手') AS agent_name
  FROM public.conversations c
  LEFT JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.ai_agents a ON a.id = c.agent_id
  WHERE c.owner_manager_id = v_root
  ORDER BY c.updated_at DESC
  LIMIT p_limit;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_conversations(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_conversations(int) TO authenticated;

-- 简化版 list_manager_health_insights_clients：同样跳过 client_relations，直接查 root_manager_id 匹配
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
  v_root uuid;
  v_is_admin boolean;
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;

  -- 平台 admin
  SELECT role = 'admin' INTO v_is_admin FROM public.profiles WHERE id = v_uid;
  IF v_is_admin THEN
    RETURN QUERY
    SELECT p.id, COALESCE(p.nickname, ''), COALESCE(p.phone, ''),
           COUNT(hi.id)::bigint
    FROM public.profiles p
    LEFT JOIN public.health_insights hi ON hi.user_id = p.id
    GROUP BY p.id, p.nickname, p.phone
    ORDER BY COUNT(hi.id) DESC
    LIMIT 200;
    RETURN;
  END IF;

  -- 企业/商户：按 root_manager_id 过滤健康洞察
  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  IF v_root IS NULL THEN RETURN; END IF;

  RETURN QUERY
  SELECT p.id, COALESCE(p.nickname, ''), COALESCE(p.phone, ''),
         COUNT(hi.id)::bigint
  FROM public.health_insights hi
  JOIN public.profiles p ON p.id = hi.user_id
  WHERE hi.root_manager_id = v_root
  GROUP BY p.id, p.nickname, p.phone
  ORDER BY COUNT(hi.id) DESC;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_health_insights_clients() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_health_insights_clients() TO authenticated;
