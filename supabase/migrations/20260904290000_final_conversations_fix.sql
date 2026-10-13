-- 终极调试：写一个最小化的 list_manager_conversations，完全不依赖 get_enterprise_root_manager_id
-- 直接返回所有 owner_manager_id = 当前用户 uid 的 + NULL 的，确认前端能看到
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
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;

  -- 路径1: 平台 admin（role='admin'）→ 看全部
  IF EXISTS (SELECT 1 FROM public.profiles WHERE id = v_uid AND role = 'admin') THEN
    RETURN QUERY
    SELECT c.id, c.user_id, c.agent_id, c.title, c.status,
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

  -- 路径2: 商户 manager 或 sub-manager
  -- 直接取 enterprise root manager id；如果返回 NULL 就把自己当 root
  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  IF v_root IS NULL THEN
    v_root := v_uid;
  END IF;

  -- 只返回本商户的 + 老的 NULL owner 数据
  RETURN QUERY
  SELECT c.id, c.user_id, c.agent_id, c.title, c.status,
         COALESCE(c.message_count, 0)::int, c.created_at, c.updated_at,
         COALESCE(p.nickname, '未命名')::text AS client_name,
         COALESCE(a.name, 'AI 助手')::text AS agent_name
  FROM public.conversations c
  LEFT JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.ai_agents a ON a.id = c.agent_id
  WHERE c.owner_manager_id = v_root
     OR c.owner_manager_id IS NULL
  ORDER BY
    CASE WHEN c.owner_manager_id = v_root THEN 0 ELSE 1 END,
    c.updated_at DESC
  LIMIT p_limit;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_conversations(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_conversations(int) TO authenticated;

-- 修 debug_whoami 的类型 bug（varchar(100) 全部统一）
DROP FUNCTION IF EXISTS public.debug_whoami();
CREATE OR REPLACE FUNCTION public.debug_whoami()
RETURNS TABLE(
  auth_uid uuid,
  root_id uuid,
  root_profile_role varchar(20),
  root_profile_nickname varchar(100),
  profile_role varchar(20),
  profile_nickname varchar(100)
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
BEGIN
  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  RETURN QUERY
  SELECT v_uid, v_root,
         rp.role::varchar(20), rp.nickname,
         p.role::varchar(20), p.nickname
  FROM public.profiles p
  LEFT JOIN public.profiles rp ON rp.id = v_root
  WHERE p.id = v_uid;
END;
$$;
GRANT EXECUTE ON FUNCTION public.debug_whoami() TO anon;
