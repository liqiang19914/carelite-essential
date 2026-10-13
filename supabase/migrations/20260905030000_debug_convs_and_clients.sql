DROP FUNCTION IF EXISTS public.debug_user_conversations_owners(uuid);
CREATE OR REPLACE FUNCTION public.debug_user_conversations_owners(p_user_id uuid)
RETURNS TABLE(id uuid, owner_manager_id uuid, title varchar(200), created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT c.id, c.owner_manager_id, c.title, c.created_at
  FROM public.conversations c
  WHERE c.user_id = p_user_id AND c.owner_manager_id IS NOT NULL
  ORDER BY c.created_at DESC LIMIT 20;
$$;
GRANT EXECUTE ON FUNCTION public.debug_user_conversations_owners(uuid) TO anon;

DROP FUNCTION IF EXISTS public.debug_manager_clients_sample(uuid);
CREATE OR REPLACE FUNCTION public.debug_manager_clients_sample(p_manager_id uuid)
RETURNS TABLE(
  client_id uuid, client_nickname varchar(100), client_role text,
  client_ent_id uuid, cr_status varchar(20)
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT cr.client_id, p.nickname, p.role::text, p.enterprise_id, cr.status
  FROM public.client_relations cr
  JOIN public.profiles p ON p.id = cr.client_id
  WHERE cr.manager_id = p_manager_id AND cr.status = 'active'
  ORDER BY cr.created_at DESC LIMIT 10;
$$;
GRANT EXECUTE ON FUNCTION public.debug_manager_clients_sample(uuid) TO anon;

DROP FUNCTION IF EXISTS public.debug_manager_clients_count(uuid);
CREATE OR REPLACE FUNCTION public.debug_manager_clients_count(p_manager_id uuid)
RETURNS TABLE(total bigint, role_dist text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_total bigint;
  v_dist text;
BEGIN
  SELECT COUNT(*) INTO v_total FROM public.client_relations cr
  WHERE cr.manager_id = p_manager_id AND cr.status = 'active';
  SELECT string_agg(r || ':' || c::text, ', ') INTO v_dist FROM (
    SELECT p.role::text AS r, COUNT(*) AS c
    FROM public.client_relations cr
    JOIN public.profiles p ON p.id = cr.client_id
    WHERE cr.manager_id = p_manager_id AND cr.status = 'active'
    GROUP BY p.role
  ) s;
  RETURN QUERY SELECT v_total, v_dist;
END;
$$;
GRANT EXECUTE ON FUNCTION public.debug_manager_clients_count(uuid) TO anon;
