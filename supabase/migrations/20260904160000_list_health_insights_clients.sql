-- 商户端健康洞察一键分析所需：列出当前商户可操作的客户列表
CREATE OR REPLACE FUNCTION public.list_manager_health_insights_clients()
RETURNS TABLE(
  id uuid,
  nickname text,
  phone text,
  insight_count bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_is_admin boolean;
BEGIN
  IF auth.uid() IS NULL THEN RETURN; END IF;

  -- 路径 A：平台 admin
  SELECT role = 'admin' INTO v_is_admin FROM public.profiles WHERE id = auth.uid();
  IF v_is_admin THEN
    RETURN QUERY
    SELECT p.id, COALESCE(p.nickname, ''), COALESCE(p.phone, ''),
           COUNT(hi.id)::bigint AS insight_count
    FROM public.profiles p
    LEFT JOIN public.health_insights hi ON hi.user_id = p.id
    GROUP BY p.id, p.nickname, p.phone
    ORDER BY insight_count DESC, p.nickname NULLS LAST
    LIMIT 200;
    RETURN;
  END IF;

  -- 路径 B：企业/商户角色
  SELECT public.get_enterprise_root_manager_id(auth.uid()) INTO v_root;
  IF v_root IS NULL THEN RETURN; END IF;

  RETURN QUERY
  SELECT p.id, COALESCE(p.nickname, ''), COALESCE(p.phone, ''),
         COUNT(hi.id)::bigint AS insight_count
  FROM public.client_relations cr
  JOIN public.profiles p ON p.id = cr.client_id
  LEFT JOIN public.health_insights hi ON hi.user_id = p.id
  WHERE cr.status = 'active'
    AND (
      cr.manager_id = auth.uid()
      OR cr.manager_id IN (
        SELECT prof.id FROM public.profiles prof
        WHERE prof.parent_manager_id = v_root AND prof.role = 'manager'
      )
      OR cr.manager_id = v_root
    )
    AND public.can_manager_view_client_data(cr.client_id, 'view_health_insights')
  GROUP BY p.id, p.nickname, p.phone
  ORDER BY insight_count DESC, p.nickname NULLS LAST;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_manager_health_insights_clients() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_manager_health_insights_clients() TO authenticated;
