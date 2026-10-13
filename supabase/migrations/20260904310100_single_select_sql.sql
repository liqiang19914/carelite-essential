-- 改 LANGUAGE sql + 单个 SELECT（不用 UNION ALL）
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
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT c.id, c.user_id, c.agent_id, c.title, c.status,
         COALESCE(c.message_count, 0)::int, c.created_at, c.updated_at,
         COALESCE(p.nickname, '未命名')::text AS client_name,
         COALESCE(a.name, 'AI 助手')::text AS agent_name
  FROM public.conversations c
  LEFT JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.ai_agents a ON a.id = c.agent_id
  WHERE auth.uid() IS NOT NULL
    AND (
      EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
      OR c.owner_manager_id = COALESCE(public.get_enterprise_root_manager_id(auth.uid()), auth.uid())
      OR c.owner_manager_id IS NULL
    )
  ORDER BY
    CASE WHEN EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN 0
         WHEN c.owner_manager_id = COALESCE(public.get_enterprise_root_manager_id(auth.uid()), auth.uid()) THEN 0
         ELSE 1 END,
    c.updated_at DESC
  LIMIT p_limit;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_conversations(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_conversations(int) TO authenticated;

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
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT m.id, m.role, m.content, m.is_flagged, m.created_at
  FROM public.messages m
  WHERE m.conversation_id = p_conversation_id
    AND auth.uid() IS NOT NULL
    AND (
      EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
      OR EXISTS (
        SELECT 1 FROM public.conversations c
        WHERE c.id = p_conversation_id
          AND (
            c.owner_manager_id = auth.uid()
            OR c.owner_manager_id = COALESCE(public.get_enterprise_root_manager_id(auth.uid()), auth.uid())
            OR c.owner_manager_id IS NULL
          )
      )
    )
  ORDER BY m.created_at ASC
  LIMIT p_limit;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_conversation_messages(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_conversation_messages(uuid, int) TO authenticated;
