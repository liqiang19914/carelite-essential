-- 修复版 list_manager_conversations：用 get_enterprise_root_manager_id 取 root + 支持企业 admin 角色
-- 与健康洞察 RPC 一致的权限模型
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

  -- 路径 A：平台 admin 看全部
  SELECT role = 'admin' INTO v_is_admin FROM public.profiles WHERE id = v_uid;
  IF v_is_admin THEN
    RETURN QUERY
    SELECT
      c.id, c.user_id, c.agent_id, c.title, c.status,
      COALESCE(c.message_count, 0), c.created_at, c.updated_at,
      COALESCE(p.nickname, '未命名') AS client_name,
      COALESCE(a.name, 'AI 助手') AS agent_name
    FROM public.conversations c
    LEFT JOIN public.profiles p ON p.id = c.user_id
    LEFT JOIN public.ai_agents a ON a.id = c.agent_id
    WHERE c.owner_manager_id IS NOT NULL
    ORDER BY c.updated_at DESC
    LIMIT p_limit;
    RETURN;
  END IF;

  -- 路径 B：企业/商户角色
  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  IF v_root IS NULL THEN RETURN; END IF;

  RETURN QUERY
  WITH visible_users AS (
    SELECT DISTINCT cr.client_id AS uid
    FROM public.client_relations cr
    WHERE cr.status = 'active'
      AND (
        cr.manager_id = v_uid
        OR cr.manager_id IN (
          SELECT prof.id FROM public.profiles prof
          WHERE prof.parent_manager_id = v_root AND prof.role = 'manager'
        )
        OR cr.manager_id = v_root
      )
  )
  SELECT
    c.id, c.user_id, c.agent_id, c.title, c.status,
    COALESCE(c.message_count, 0)::int, c.created_at, c.updated_at,
    COALESCE(p.nickname, '未命名') AS client_name,
    COALESCE(a.name, 'AI 助手') AS agent_name
  FROM public.conversations c
  JOIN visible_users vu ON vu.uid = c.user_id
  LEFT JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.ai_agents a ON a.id = c.agent_id
  WHERE c.owner_manager_id = v_root
  ORDER BY c.updated_at DESC
  LIMIT p_limit;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_conversations(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_conversations(int) TO authenticated;

-- 会话消息 RPC：SECURITY DEFINER，按 conversation owner 校验归属
CREATE OR REPLACE FUNCTION public.list_manager_conversation_messages(
  p_conversation_id uuid,
  p_limit int DEFAULT 100
)
RETURNS TABLE (
  id uuid,
  role text,
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

  -- 路径 A：平台 admin
  SELECT role = 'admin' INTO v_is_admin FROM public.profiles WHERE id = v_uid;
  IF v_is_admin THEN
    RETURN QUERY
    SELECT m.id, m.role, m.content, m.is_flagged, m.created_at
    FROM public.messages m
    WHERE m.conversation_id = p_conversation_id
    ORDER BY m.created_at ASC
    LIMIT p_limit;
    RETURN;
  END IF;

  -- 路径 B：企业/商户角色，校验 conversation.owner_manager_id 是否归属
  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  IF v_root IS NULL THEN RETURN; END IF;

  -- 对话 owner 必须等于当前 root_manager
  IF NOT EXISTS (
    SELECT 1 FROM public.conversations c
    WHERE c.id = p_conversation_id
      AND c.owner_manager_id = v_root
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
