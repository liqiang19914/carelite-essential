-- health_insights_clients: 用 p_ 前缀避免 PL/pgSQL RETURNS TABLE 列名冲突
DROP FUNCTION IF EXISTS public.list_manager_health_insights_clients(text, int, int);

CREATE OR REPLACE FUNCTION public.list_manager_health_insights_clients(
  p_search text DEFAULT '',
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
)
RETURNS TABLE(
  p_id uuid,
  p_nickname varchar(100),
  p_phone varchar(30),
  p_insight_count bigint,
  p_last_analyzed_at timestamptz,
  p_critical_count bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_ent_id uuid;
  v_is_admin boolean;
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;

  SELECT role = 'admin' INTO v_is_admin FROM public.profiles WHERE id = v_uid;

  IF v_is_admin THEN
    RETURN QUERY
    SELECT u.id, u.nickname, u.phone,
           COALESCE(sub.hi_cnt, 0)::bigint,
           sub.hi_last_at,
           COALESCE(sub.hi_crit, 0)::bigint
    FROM public.profiles u
    LEFT JOIN (
      SELECT hi2.user_id,
             COUNT(*) AS hi_cnt,
             MAX(hi2.analyzed_at) AS hi_last_at,
             COUNT(*) FILTER (WHERE hi2.severity = 'critical') AS hi_crit
      FROM public.health_insights hi2
      GROUP BY hi2.user_id
    ) sub ON sub.user_id = u.id
    WHERE (sub.hi_cnt > 0 OR EXISTS (SELECT 1 FROM public.conversations c WHERE c.user_id = u.id))
      AND (p_search = '' OR u.nickname ILIKE '%' || p_search || '%' OR COALESCE(u.phone, '') ILIKE '%' || p_search || '%')
    ORDER BY sub.hi_cnt DESC NULLS LAST, sub.hi_last_at DESC NULLS LAST
    LIMIT p_limit OFFSET p_offset;
    RETURN;
  END IF;

  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  IF v_root IS NULL THEN v_root := v_uid; END IF;
  SELECT enterprise_id INTO v_ent_id FROM public.profiles WHERE id = v_root;

  RETURN QUERY
  SELECT u.id, u.nickname, u.phone,
         COALESCE(sub.hi_cnt, 0)::bigint,
         sub.hi_last_at,
         COALESCE(sub.hi_crit, 0)::bigint
  FROM public.profiles u
  LEFT JOIN (
    SELECT hi2.user_id,
           COUNT(*) AS hi_cnt,
           MAX(hi2.analyzed_at) AS hi_last_at,
           COUNT(*) FILTER (WHERE hi2.severity = 'critical') AS hi_crit
    FROM public.health_insights hi2
    GROUP BY hi2.user_id
  ) sub ON sub.user_id = u.id
  WHERE u.role = 'user'
    AND (
      u.id IN (
        SELECT cr.client_id FROM public.client_relations cr
        WHERE cr.status = 'active' AND cr.manager_id IN (
          SELECT p2.id FROM public.profiles p2
          WHERE p2.id = v_root OR p2.parent_manager_id = v_root
        )
      )
      OR (v_ent_id IS NOT NULL AND u.enterprise_id = v_ent_id)
    )
    AND (p_search = '' OR u.nickname ILIKE '%' || p_search || '%' OR COALESCE(u.phone, '') ILIKE '%' || p_search || '%')
  ORDER BY sub.hi_cnt DESC NULLS LAST, sub.hi_last_at DESC NULLS LAST
  LIMIT p_limit OFFSET p_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_health_insights_clients(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_health_insights_clients(text, int, int) TO authenticated;

-- Debug: 直接查 conversations 表里 owner_manager_id 的真实分布（卓越耀美 5424dfb1）
DROP FUNCTION IF EXISTS public.debug_conv_owner_distribution();
CREATE OR REPLACE FUNCTION public.debug_conv_owner_distribution()
RETURNS TABLE(owner_id uuid, cnt bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT c.owner_manager_id, COUNT(*)::bigint FROM public.conversations c GROUP BY c.owner_manager_id ORDER BY COUNT(*) DESC;
$$;
GRANT EXECUTE ON FUNCTION public.debug_conv_owner_distribution() TO anon;

-- Debug: 李强的对话 owner 分布
DROP FUNCTION IF EXISTS public.debug_user_conv_owners(uuid);
CREATE OR REPLACE FUNCTION public.debug_user_conv_owners(p_user_id uuid)
RETURNS TABLE(conv_id uuid, conv_title varchar(200), owner_manager_id uuid, ent_id uuid, ent_match_root boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT c.id, c.title, c.owner_manager_id, p.enterprise_id,
         CASE WHEN p.enterprise_id = (SELECT enterprise_id FROM public.profiles WHERE id = '5424dfb1-f528-436c-bd75-2028e3c2e286') THEN true ELSE false END
  FROM public.conversations c
  JOIN public.profiles p ON p.id = c.user_id
  WHERE c.user_id = p_user_id
  ORDER BY c.created_at DESC LIMIT 30;
$$;
GRANT EXECUTE ON FUNCTION public.debug_user_conv_owners(uuid) TO anon;
