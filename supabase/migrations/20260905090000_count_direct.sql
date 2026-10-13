-- 最简单直接查 count，绕过函数
DROP FUNCTION IF EXISTS public.debug_count_direct(uuid);
CREATE OR REPLACE FUNCTION public.debug_count_direct(p_root uuid)
RETURNS TABLE(label text, cnt bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT 'owner='||p_root::text, COUNT(*)::bigint FROM public.conversations WHERE owner_manager_id = p_root
  UNION ALL
  SELECT 'owner IS NULL', COUNT(*)::bigint FROM public.conversations WHERE owner_manager_id IS NULL
  UNION ALL
  SELECT 'total', COUNT(*)::bigint FROM public.conversations;
$$;
GRANT EXECUTE ON FUNCTION public.debug_count_direct(uuid) TO anon;

-- 用同样的 WHERE 逻辑跑 SELECT，看实际返回什么
DROP FUNCTION IF EXISTS public.debug_where_test(uuid);
CREATE OR REPLACE FUNCTION public.debug_where_test(p_root uuid, p_ent_id uuid)
RETURNS TABLE(id uuid, title varchar(200), owner_manager_id uuid, user_ent_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT c.id, c.title, c.owner_manager_id, p.enterprise_id
  FROM public.conversations c
  JOIN public.profiles p ON p.id = c.user_id
  WHERE auth.uid() IS NOT NULL
    AND (
      c.owner_manager_id = p_root
      OR (c.owner_manager_id IS NULL AND p.enterprise_id IS NOT NULL AND p.enterprise_id = p_ent_id)
    )
  ORDER BY c.created_at DESC LIMIT 50;
$$;
GRANT EXECUTE ON FUNCTION public.debug_where_test(uuid, uuid) TO authenticated;
