-- 临时 debug RPC：列出 conversations 表里**所有**行（不管 owner_manager_id），用于排查数据流向
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
  SELECT c.id, c.user_id, c.owner_manager_id, c.agent_id, c.title, c.status,
         COALESCE(c.message_count, 0)::int, c.created_at, c.updated_at
  FROM public.conversations c
  ORDER BY c.updated_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.debug_list_all_conversations(int) TO anon;
GRANT EXECUTE ON FUNCTION public.debug_list_all_conversations(int) TO authenticated;

-- 临时 debug：messages 总数
CREATE OR REPLACE FUNCTION public.debug_count_messages()
RETURNS bigint
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN (SELECT COUNT(*) FROM public.messages);
END;
$$;

GRANT EXECUTE ON FUNCTION public.debug_count_messages() TO anon;

-- 临时 debug：看 profiles 表 role 分布
CREATE OR REPLACE FUNCTION public.debug_profile_role_distribution()
RETURNS TABLE(role text, cnt bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT p.role::text, COUNT(*)::bigint FROM public.profiles p GROUP BY p.role ORDER BY COUNT(*) DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.debug_profile_role_distribution() TO anon;

-- 临时 debug：看 managers 表有没有记录 + 与 profiles 关联情况
CREATE OR REPLACE FUNCTION public.debug_managers_sample(p_limit int DEFAULT 10)
RETURNS TABLE(id uuid, business_name text, company_name text, parent_id uuid, profile_id uuid, profile_role text, profile_nickname text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT m.id, m.business_name, m.company_name, m.parent_manager_id, p.id, p.role::text, p.nickname
  FROM public.managers m
  LEFT JOIN public.profiles p ON p.id = m.id
  ORDER BY m.created_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.debug_managers_sample(int) TO anon;
