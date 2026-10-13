-- 20260905070000: 强制覆盖 list_manager_conversations + list_manager_health_insights_clients
-- 确保不带 OR NULL owner fallback，并且 health_insights_clients 有正确签名

-- ========== list_manager_conversations ==========
DROP FUNCTION IF EXISTS public.list_manager_conversations(int);
DROP FUNCTION IF EXISTS public.list_manager_conversations();

CREATE OR REPLACE FUNCTION public.list_manager_conversations(
  p_limit int DEFAULT 200
)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  agent_id uuid,
  title varchar(200),
  status varchar(20),
  message_count int,
  created_at timestamptz,
  updated_at timestamptz,
  client_name text,
  agent_name text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT c.id, c.user_id, c.agent_id, c.title, c.status,
         COALESCE(c.message_count, 0)::int, c.created_at, c.updated_at,
         COALESCE(p.nickname, '未命名')::text AS client_name,
         COALESCE(a.name, 'AI 助手')::text AS agent_name
  FROM public.conversations c
  LEFT JOIN public.profiles p ON p.id = c.user_id
  LEFT JOIN public.ai_agents a ON a.id = c.agent_id
  WHERE auth.uid() IS NOT NULL
    AND (
      EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
      OR c.owner_manager_id = COALESCE(public.get_enterprise_root_manager_id(auth.uid()), auth.uid())
      OR (
        c.owner_manager_id IS NULL
        AND p.enterprise_id IS NOT NULL
        AND p.enterprise_id = (SELECT pr.enterprise_id FROM public.profiles pr WHERE pr.id = auth.uid())
      )
    )
  ORDER BY c.updated_at DESC
  LIMIT p_limit;
$$;

REVOKE ALL ON FUNCTION public.list_manager_conversations(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_conversations(int) TO authenticated;

-- ========== list_manager_health_insights_clients（带参数版）==========
DROP FUNCTION IF EXISTS public.list_manager_health_insights_clients();
DROP FUNCTION IF EXISTS public.list_manager_health_insights_clients(text, int, int);

CREATE OR REPLACE FUNCTION public.list_manager_health_insights_clients(
  p_search text DEFAULT '',
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
)
RETURNS TABLE(
  id uuid,
  nickname varchar(100),
  phone varchar(30),
  insight_count bigint,
  last_analyzed_at timestamptz,
  critical_count bigint
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
           COALESCE(sub.hi_cnt, 0)::bigint AS insight_count,
           sub.hi_last_at AS last_analyzed_at,
           COALESCE(sub.hi_crit, 0)::bigint AS critical_count
    FROM public.profiles u
    LEFT JOIN (
      SELECT hi.user_id,
             COUNT(*) AS hi_cnt,
             MAX(hi.analyzed_at) AS hi_last_at,
             COUNT(*) FILTER (WHERE hi.severity = 'critical') AS hi_crit
      FROM public.health_insights hi
      GROUP BY hi.user_id
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
         COALESCE(sub.hi_cnt, 0)::bigint AS insight_count,
         sub.hi_last_at AS last_analyzed_at,
         COALESCE(sub.hi_crit, 0)::bigint AS critical_count
  FROM public.profiles u
  LEFT JOIN (
    SELECT hi.user_id,
           COUNT(*) AS hi_cnt,
           MAX(hi.analyzed_at) AS hi_last_at,
           COUNT(*) FILTER (WHERE hi.severity = 'critical') AS hi_crit
    FROM public.health_insights hi
    GROUP BY hi.user_id
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
