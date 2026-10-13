-- 修复所有 RPC 的列类型不匹配问题（varchar vs text）
DROP FUNCTION IF EXISTS public.list_manager_conversations(int);
CREATE OR REPLACE FUNCTION public.list_manager_conversations(
  p_limit int DEFAULT 200
)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  agent_id uuid,
  title varchar(200),
  status varchar(20),
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

  RETURN QUERY
  SELECT
    c.id, c.user_id, c.agent_id, c.title, c.status,
    COALESCE(c.message_count, 0)::int, c.created_at, c.updated_at,
    COALESCE(p.nickname, '未命名')::text AS client_name,
    COALESCE(a.name, 'AI 助手')::text AS agent_name
  FROM public.conversations c
  LEFT JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.ai_agents a ON a.id = c.agent_id
  ORDER BY c.updated_at DESC
  LIMIT p_limit;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_conversations(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_conversations(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_manager_conversations(int) TO anon;

-- 同样修 list_manager_conversation_messages（如果也有类型问题）
DROP FUNCTION IF EXISTS public.list_manager_conversation_messages(uuid, int);
CREATE OR REPLACE FUNCTION public.list_manager_conversation_messages(
  p_conversation_id uuid,
  p_limit int DEFAULT 100
)
RETURNS TABLE (
  id uuid,
  role varchar(20),
  content text,
  is_flagged boolean,
  created_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;

  RETURN QUERY
  SELECT m.id, m.role, m.content, m.is_flagged, m.created_at
  FROM public.messages m
  WHERE m.conversation_id = p_conversation_id
  ORDER BY m.created_at ASC
  LIMIT p_limit;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_conversation_messages(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_conversation_messages(uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_manager_conversation_messages(uuid, int) TO anon;

-- 清理 debug RPC（已经用不上了）
DROP FUNCTION IF EXISTS public.debug_list_all_conversations(int);
DROP FUNCTION IF EXISTS public.debug_count_messages();
DROP FUNCTION IF EXISTS public.debug_profile_role_distribution();
DROP FUNCTION IF EXISTS public.debug_managers_sample(int);
DROP FUNCTION IF EXISTS public.debug_messages_sample(int);
