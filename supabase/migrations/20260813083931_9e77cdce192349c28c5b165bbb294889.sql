-- 判断商户是否有权查看某客户的指定数据类型
-- 三级闸门：平台已授予 → 商户已开启 → 客户隐私开关通过
CREATE OR REPLACE FUNCTION public.can_manager_view_client_data(
  p_client_id uuid,
  p_module_key text  -- 'view_health_records' | 'view_health_insights' | 'view_conversations'
)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM client_relations cr
    JOIN merchant_module_grants g
      ON g.manager_id = get_enterprise_root_manager_id(cr.manager_id)
     AND g.module_key = p_module_key
     AND g.grant_status = 'granted'
     AND g.is_enabled = true
    WHERE cr.client_id = p_client_id
      AND cr.status = 'active'
      AND cr.manager_id = auth.uid()
  );
$$;