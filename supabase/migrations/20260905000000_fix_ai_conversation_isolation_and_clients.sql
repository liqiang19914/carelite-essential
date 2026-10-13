-- 先只修 list_manager_conversations（SQL 函数 + UNION ALL 在 SQL 函数里对 RETURNS TABLE 要小心）
-- 用 CASE WHEN 替代 UNION ALL
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
      OR (
        c.owner_manager_id IS NULL
        AND p.enterprise_id IS NOT NULL
        AND p.enterprise_id = (SELECT enterprise_id FROM public.profiles WHERE id = auth.uid())
      )
    )
  ORDER BY c.updated_at DESC
  LIMIT p_limit;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_conversations(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_conversations(int) TO authenticated;
