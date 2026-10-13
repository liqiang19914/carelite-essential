-- 修 debug_whoami 类型（varchar(100) vs text，又是这个 bug）
DROP FUNCTION IF EXISTS public.debug_whoami();
CREATE OR REPLACE FUNCTION public.debug_whoami()
RETURNS TABLE(
  auth_uid uuid,
  root_id uuid,
  root_profile_role varchar(20),
  root_profile_nickname text,
  profile_role varchar(20),
  profile_nickname text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
BEGIN
  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  RETURN QUERY
  SELECT
    v_uid,
    v_root,
    rp.role::varchar(20),
    rp.nickname,
    p.role::varchar(20),
    p.nickname
  FROM public.profiles p
  LEFT JOIN public.profiles rp ON rp.id = v_root
  WHERE p.id = v_uid;
END;
$$;
GRANT EXECUTE ON FUNCTION public.debug_whoami() TO anon;

-- 新 debug：按 conversations.user_id 查 profile 的 enterprise_id，看 NULL owner 的对话实际属于哪个 enterprise
DROP FUNCTION IF EXISTS public.debug_null_owner_conversations(int);
CREATE OR REPLACE FUNCTION public.debug_null_owner_conversations(p_limit int DEFAULT 10)
RETURNS TABLE(
  conv_id uuid,
  user_id uuid,
  user_nickname text,
  user_enterprise_id uuid,
  enterprise_name text,
  enterprise_root_profile_id uuid,
  conv_count bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT DISTINCT ON (hi.enterprise_root_profile_id)
    c.id, c.user_id, p.nickname,
    p.enterprise_id, e.name,
    e.owner_profile_id AS enterprise_root_profile_id,
    COUNT(*) OVER (PARTITION BY e.owner_profile_id)::bigint
  FROM public.conversations c
  LEFT JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.enterprises e ON e.id = p.enterprise_id
  WHERE c.owner_manager_id IS NULL
  ORDER BY e.owner_profile_id NULLS LAST, c.created_at DESC
  LIMIT p_limit;
END;
$$;
GRANT EXECUTE ON FUNCTION public.debug_null_owner_conversations(int) TO anon;

-- 全局 manager role 分布（不带 auth，让 anon 能调）
DROP FUNCTION IF EXISTS public.debug_all_root_managers(int);
CREATE OR REPLACE FUNCTION public.debug_all_root_managers(p_limit int DEFAULT 20)
RETURNS TABLE(id uuid, nickname text, enterprise_id uuid, enterprise_name text, is_admin boolean)
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
