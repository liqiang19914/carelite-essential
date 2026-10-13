DROP FUNCTION IF EXISTS public.debug_list_all_conversations(int);
CREATE OR REPLACE FUNCTION public.debug_list_all_conversations(p_limit int DEFAULT 100)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  owner_manager_id uuid,
  agent_id uuid,
  title text,
  status text,
  message_count int,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT c.id, c.user_id, c.owner_manager_id, c.agent_id,
         c.title::text, c.status::text,
         COALESCE(c.message_count, 0)::int, c.created_at, c.updated_at
  FROM public.conversations c
  ORDER BY c.updated_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.debug_list_all_conversations(int) TO anon;

DROP FUNCTION IF EXISTS public.debug_managers_sample(int);
CREATE OR REPLACE FUNCTION public.debug_managers_sample(p_limit int DEFAULT 10)
RETURNS TABLE(id uuid, business_name text, company_name text, profile_id uuid, profile_role text, profile_nickname text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT m.id, m.business_name, m.company_name, p.id, p.role::text, p.nickname
  FROM public.managers m
  LEFT JOIN public.profiles p ON p.id = m.id
  ORDER BY m.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.debug_managers_sample(int) TO anon;

-- messages 表结构探
DROP FUNCTION IF EXISTS public.debug_messages_sample(int);
CREATE OR REPLACE FUNCTION public.debug_messages_sample(p_limit int DEFAULT 5)
RETURNS TABLE(id uuid, conversation_id uuid, role text, content text, created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT m.id, m.conversation_id, m.role::text, LEFT(m.content, 100), m.created_at
  FROM public.messages m
  ORDER BY m.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.debug_messages_sample(int) TO anon;
