-- 修复3+4：模块闸门函数（含企业范围），客户数据可见性函数补上隐私开关
CREATE OR REPLACE FUNCTION public.module_open_for_client(p_client_id uuid, p_module_key text)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.client_relations cr
    JOIN public.merchant_module_grants g
      ON g.manager_id = public.get_enterprise_root_manager_id(cr.manager_id)
     AND g.module_key = p_module_key
     AND g.grant_status = 'granted'
     AND g.is_enabled = true
    WHERE cr.client_id = p_client_id
      AND cr.status = 'active'
      AND (
        cr.manager_id = (SELECT auth.uid())
        OR public.is_enterprise_member_for_admin(cr.manager_id, (SELECT auth.uid()))
      )
  );
$$;

CREATE OR REPLACE FUNCTION public.can_manager_view_client_data(p_client_id uuid, p_module_key text)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  -- 三级闸门：平台授予+商户开启（module_open_for_client）→ 客户隐私开关
  SELECT public.module_open_for_client(p_client_id, p_module_key)
    AND public.can_manager_view_client_category(
      p_client_id,
      CASE p_module_key
        WHEN 'view_health_records'  THEN 'share_records'
        WHEN 'view_health_insights' THEN 'data_analysis'
        WHEN 'view_conversations'   THEN 'data_analysis'
        ELSE 'share_records'
      END
    );
$$;

REVOKE EXECUTE ON FUNCTION public.module_open_for_client(uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.can_manager_view_client_data(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.module_open_for_client(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_manager_view_client_data(uuid, text) TO authenticated;