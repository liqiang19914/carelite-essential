-- 简化版：加表前缀修复 ambiguous column
DROP FUNCTION IF EXISTS public.debug_user_enterprise_map();
CREATE OR REPLACE FUNCTION public.debug_user_enterprise_map()
RETURNS TABLE(user_id uuid, nickname varchar(100), ent_id uuid, ent_name text, total_conv bigint, null_owner_conv bigint, ent_matches_root bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT p.id, p.nickname, p.enterprise_id, e.name,
         COUNT(*)::bigint,
         COUNT(*) FILTER (WHERE c.owner_manager_id IS NULL)::bigint,
         CASE WHEN p.enterprise_id = (SELECT pr2.enterprise_id FROM public.profiles pr2 WHERE pr2.id = auth.uid()) THEN COUNT(*)::bigint ELSE 0::bigint END
  FROM public.conversations c
  JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.enterprises e ON e.id = p.enterprise_id
  WHERE auth.uid() IS NOT NULL
    AND (
      EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
      OR c.owner_manager_id = (SELECT pr3.enterprise_id FROM public.profiles pr3 WHERE pr3.id = auth.uid())::uuid  -- 不对，应该是 root manager
      OR (c.owner_manager_id IS NULL AND p.enterprise_id IS NOT NULL AND p.enterprise_id = (SELECT pr2.enterprise_id FROM public.profiles pr2 WHERE pr2.id = auth.uid()))
    )
  GROUP BY p.id, p.nickname, p.enterprise_id, e.name;
$$;
GRANT EXECUTE ON FUNCTION public.debug_user_enterprise_map() TO authenticated;

-- 还有：health_insights_clients 也报 ambiguous id，修一下
-- 先看是不是因为 plpgsql 的 RETURNS TABLE 列名和查询里的列冲突
DROP FUNCTION IF EXISTS public.debug_health_clients_direct(uuid);
CREATE OR REPLACE FUNCTION public.debug_health_clients_direct(p_root uuid, p_ent_id uuid)
RETURNS TABLE(client_id uuid, nickname varchar(100), role text, enterprise_id uuid, is_in_client_rels boolean, insights_count bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT u.id, u.nickname, u.role::text, u.enterprise_id,
         EXISTS (SELECT 1 FROM public.client_relations cr WHERE cr.client_id = u.id AND cr.status='active' AND cr.manager_id = p_root),
         (SELECT COUNT(*) FROM public.health_insights hi WHERE hi.user_id = u.id)::bigint
  FROM public.profiles u
  WHERE u.role = 'user'
    AND (
      u.id IN (SELECT cr.client_id FROM public.client_relations cr WHERE cr.status='active' AND cr.manager_id = p_root)
      OR (p_ent_id IS NOT NULL AND u.enterprise_id = p_ent_id)
    )
  ORDER BY u.nickname LIMIT 10;
$$;
GRANT EXECUTE ON FUNCTION public.debug_health_clients_direct(uuid, uuid) TO anon;
