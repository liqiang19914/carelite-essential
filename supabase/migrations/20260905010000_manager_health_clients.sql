-- 单独修 list_manager_health_insights_clients：plpgsql 更灵活
-- 查商户所有客户：client_relations + enterprise_id 匹配 + 带 insight 统计
DROP FUNCTION IF EXISTS public.list_manager_health_insights_clients();
CREATE OR REPLACE FUNCTION public.list_manager_health_insights_clients()
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

  -- 路径1：admin → 全平台所有 profiles 下有对话或有洞察的
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
    WHERE sub.hi_cnt > 0
       OR EXISTS (SELECT 1 FROM public.conversations c WHERE c.user_id = u.id)
    ORDER BY sub.hi_cnt DESC NULLS LAST, sub.hi_last_at DESC NULLS LAST;
    RETURN;
  END IF;

  -- 路径2：商户
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
      -- client_relations：该商户所有健管师名下的客户
      u.id IN (
        SELECT cr.client_id FROM public.client_relations cr
        WHERE cr.status = 'active' AND cr.manager_id IN (
          SELECT p2.id FROM public.profiles p2
          WHERE p2.id = v_root OR p2.parent_manager_id = v_root
        )
      )
      -- enterprise_id 匹配：同 enterprise 的所有用户
      OR (v_ent_id IS NOT NULL AND u.enterprise_id = v_ent_id)
    )
  ORDER BY sub.hi_cnt DESC NULLS LAST, sub.hi_last_at DESC NULLS LAST;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_health_insights_clients() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_health_insights_clients() TO authenticated;
