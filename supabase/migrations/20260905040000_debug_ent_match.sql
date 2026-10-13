DROP FUNCTION IF EXISTS public.debug_user_enterprise_map();
CREATE OR REPLACE FUNCTION public.debug_user_enterprise_map()
RETURNS TABLE(user_id uuid, nickname varchar(100), enterprise_id uuid, ent_name text, total_conv bigint, null_owner_conv bigint, ent_matches_root bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_root uuid;
  v_ent_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RETURN; END IF;
  SELECT public.get_enterprise_root_manager_id(auth.uid()) INTO v_root;
  IF v_root IS NULL THEN v_root := auth.uid(); END IF;
  SELECT enterprise_id INTO v_ent_id FROM public.profiles WHERE id = v_root;

  RETURN QUERY
  SELECT p.id, p.nickname, p.enterprise_id, e.name,
         COUNT(*)::bigint,
         COUNT(*) FILTER (WHERE c.owner_manager_id IS NULL)::bigint,
         CASE WHEN v_ent_id IS NOT NULL AND p.enterprise_id = v_ent_id THEN COUNT(*)::bigint ELSE 0::bigint END
  FROM public.conversations c
  JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.enterprises e ON e.id = p.enterprise_id
  WHERE auth.uid() IS NOT NULL
    AND (
      EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
      OR c.owner_manager_id = v_root
      OR (c.owner_manager_id IS NULL AND p.enterprise_id IS NOT NULL AND p.enterprise_id = v_ent_id)
    )
  GROUP BY p.id, p.nickname, p.enterprise_id, e.name;
END;
$$;
GRANT EXECUTE ON FUNCTION public.debug_user_enterprise_map() TO authenticated;
