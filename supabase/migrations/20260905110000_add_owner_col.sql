-- 给 list_manager_conversations 加 owner_manager_id 列，方便前端排查
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
  owner_manager_id uuid,
  client_name text,
  agent_name text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT c.id, c.user_id, c.agent_id, c.title, c.status,
         COALESCE(c.message_count, 0)::int, c.created_at, c.updated_at,
         c.owner_manager_id,
         COALESCE(p.nickname, '未命名')::text AS client_name,
         COALESCE(a.name, 'AI 助手')::text AS agent_name
  FROM public.conversations c
  LEFT JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.ai_agents a ON a.id = c.agent_id
  WHERE auth.uid() IS NOT NULL
    AND (
      EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
      OR c.owner_manager_id = COALESCE(public.get_enterprise_root_manager_id(auth.uid()), auth.uid())
      OR (
        c.owner_manager_id IS NULL
        AND p.enterprise_id IS NOT NULL
        AND p.enterprise_id = (SELECT pr.enterprise_id FROM public.profiles pr WHERE pr.id = auth.uid())
      )
    )
  ORDER BY c.updated_at DESC
  LIMIT p_limit;
$$;

REVOKE ALL ON FUNCTION public.list_manager_conversations(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_conversations(int) TO authenticated;
