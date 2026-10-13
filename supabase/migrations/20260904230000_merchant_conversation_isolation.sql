-- 商户对话隔离：list_manager_conversations 按 owner_manager_id = root_manager_id 过滤
-- 平台 admin 看全部；同商户下所有健管师（sub-manager + root）都看这个商户的对话
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
  v_root uuid;
  v_is_admin boolean;
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;

  SELECT role = 'admin' INTO v_is_admin FROM public.profiles WHERE id = v_uid;

  -- 平台 admin 看全部（包含所有商户 + 无归属的通用对话）
  IF v_is_admin THEN
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
    RETURN;
  END IF;

  -- 企业/商户：取 root manager id
  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  IF v_root IS NULL THEN RETURN; END IF;

  -- 只返回本商户 owner_manager_id = v_root 的对话
  RETURN QUERY
  SELECT
    c.id, c.user_id, c.agent_id, c.title, c.status,
    COALESCE(c.message_count, 0)::int, c.created_at, c.updated_at,
    COALESCE(p.nickname, '未命名')::text AS client_name,
    COALESCE(a.name, 'AI 助手')::text AS agent_name
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

-- 会话消息 RPC：同样按 conversation.owner_manager_id 校验归属
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
  v_root uuid;
  v_is_admin boolean;
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;

  -- 查对话归属
  SELECT c.owner_manager_id INTO v_root
  FROM public.conversations c WHERE c.id = p_conversation_id;

  -- 平台 admin 或对话归属自己 → 放行
  SELECT role = 'admin' INTO v_is_admin FROM public.profiles WHERE id = v_uid;
  IF v_is_admin OR v_root = v_uid THEN
    RETURN QUERY
    SELECT m.id, m.role, m.content, m.is_flagged, m.created_at
    FROM public.messages m
    WHERE m.conversation_id = p_conversation_id
    ORDER BY m.created_at ASC
    LIMIT p_limit;
    RETURN;
  END IF;

  -- 企业/商户：当前用户的 root manager id 必须等于对话的 owner_manager_id
  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  IF v_root IS NULL THEN RETURN; END IF;

  -- 再查一次对话归属比对
  IF NOT EXISTS (
    SELECT 1 FROM public.conversations c
    WHERE c.id = p_conversation_id AND c.owner_manager_id = v_root
  ) THEN
    RETURN;
  END IF;

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
