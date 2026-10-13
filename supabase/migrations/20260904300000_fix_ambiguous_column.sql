-- 修 list_manager_conversations 的 42702 ambiguous column reference
-- RETURNS TABLE 列名和 LEFT JOIN 的同名列（profiles.id, ai_agents.id）冲突
-- 在 SELECT 里显式加表前缀即可
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

  -- 路径1: 平台 admin
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

  -- 路径2: 商户 manager / sub-manager
  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  IF v_root IS NULL THEN
    v_root := v_uid;
  END IF;

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
