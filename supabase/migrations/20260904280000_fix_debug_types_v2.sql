-- 修 debug RPC 的类型 bug 和 debug_null_owner_conversations 的 SQL 错误
DROP FUNCTION IF EXISTS public.debug_all_root_managers(int);
CREATE OR REPLACE FUNCTION public.debug_all_root_managers(p_limit int DEFAULT 20)
RETURNS TABLE(id uuid, nickname varchar(100), enterprise_id uuid, enterprise_name text, is_admin boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT p.id, p.nickname, p.enterprise_id, e.name, (p.role = 'admin')
  FROM public.profiles p
  LEFT JOIN public.enterprises e ON e.id = p.enterprise_id
  WHERE (p.role = 'manager' AND p.parent_manager_id IS NULL) OR p.role = 'admin'
  ORDER BY p.role DESC, p.created_at DESC
  LIMIT p_limit;
END;
$$;
GRANT EXECUTE ON FUNCTION public.debug_all_root_managers(int) TO anon;

DROP FUNCTION IF EXISTS public.debug_null_owner_conversations(int);
CREATE OR REPLACE FUNCTION public.debug_null_owner_conversations(p_limit int DEFAULT 20)
RETURNS TABLE(
  user_id uuid,
  user_nickname varchar(100),
  enterprise_id uuid,
  enterprise_root_profile_id uuid,
  cnt bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.user_id,
    p.nickname,
    p.enterprise_id,
    e.owner_profile_id,
    COUNT(*)::bigint
  FROM public.conversations c
  LEFT JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.enterprises e ON e.id = p.enterprise_id
  WHERE c.owner_manager_id IS NULL
  GROUP BY c.user_id, p.nickname, p.enterprise_id, e.owner_profile_id
  ORDER BY COUNT(*) DESC
  LIMIT p_limit;
END;
$$;
GRANT EXECUTE ON FUNCTION public.debug_null_owner_conversations(int) TO anon;
