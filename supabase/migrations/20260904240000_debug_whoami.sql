-- Debug: 查当前 auth.uid() 映射到哪个 root manager
CREATE OR REPLACE FUNCTION public.debug_whoami()
RETURNS TABLE(
  auth_uid uuid,
  root_id uuid,
  root_profile_role text,
  root_profile_nickname text,
  profile_role text,
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
    rp.role::text,
    rp.nickname,
    p.role::text,
    p.nickname
  FROM public.profiles p
  LEFT JOIN public.profiles rp ON rp.id = v_root
  WHERE p.id = v_uid;
END;
$$;

GRANT EXECUTE ON FUNCTION public.debug_whoami() TO anon;

-- Debug: conversations 按 owner_manager_id 分组统计
CREATE OR REPLACE FUNCTION public.debug_conversations_by_owner()
RETURNS TABLE(owner_manager_id uuid, cnt bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT c.owner_manager_id, COUNT(*)::bigint
  FROM public.conversations c
  GROUP BY c.owner_manager_id
  ORDER BY COUNT(*) DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.debug_conversations_by_owner() TO anon;

-- Debug: health_insights 表样本 + 列类型
CREATE OR REPLACE FUNCTION public.debug_health_insights_sample(p_limit int DEFAULT 3)
RETURNS TABLE(id uuid, user_id uuid, category varchar(50), title text, severity varchar(20), root_manager_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT hi.id, hi.user_id, hi.category, hi.title, hi.severity, hi.root_manager_id
  FROM public.health_insights hi
  ORDER BY hi.analyzed_at DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.debug_health_insights_sample(int) TO anon;
