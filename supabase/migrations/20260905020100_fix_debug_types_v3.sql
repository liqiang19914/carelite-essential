DROP FUNCTION IF EXISTS public.debug_profile_full(uuid);
CREATE OR REPLACE FUNCTION public.debug_profile_full(p_uid uuid)
RETURNS TABLE(
  id uuid,
  nickname varchar(100),
  phone varchar(30),
  role_text text,
  enterprise_id uuid,
  parent_manager_id uuid,
  client_rel_cnt bigint,
  enterprise_name text,
  enterprise_root_profile_id uuid
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT p.id, p.nickname, p.phone, p.role::text, p.enterprise_id, p.parent_manager_id,
         (SELECT COUNT(*) FROM public.client_relations cr WHERE cr.manager_id = p.id)::bigint,
         e.name, e.owner_profile_id
  FROM public.profiles p
  LEFT JOIN public.enterprises e ON e.id = p.enterprise_id
  WHERE p.id = p_uid;
END;
$$;
GRANT EXECUTE ON FUNCTION public.debug_profile_full(uuid) TO anon;

DROP FUNCTION IF EXISTS public.debug_user_enterprise(uuid);
CREATE OR REPLACE FUNCTION public.debug_user_enterprise(p_uid uuid)
RETURNS TABLE(
  id uuid,
  nickname varchar(100),
  role_text text,
  enterprise_id uuid,
  enterprise_name text,
  conv_cnt bigint,
  conv_null_owner bigint,
  conv_matched_owner bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT p.id, p.nickname, p.role::text, p.enterprise_id, e.name,
         COUNT(*)::bigint,
         COUNT(*) FILTER (WHERE c.owner_manager_id IS NULL)::bigint,
         COUNT(*) FILTER (WHERE c.owner_manager_id IS NOT NULL)::bigint
  FROM public.profiles p
  LEFT JOIN public.enterprises e ON e.id = p.enterprise_id
  LEFT JOIN public.conversations c ON c.user_id = p.id
  WHERE p.id = p_uid
  GROUP BY p.id, p.nickname, p.role, p.enterprise_id, e.name;
END;
$$;
GRANT EXECUTE ON FUNCTION public.debug_user_enterprise(uuid) TO anon;
