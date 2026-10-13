-- 修复4（续）：档案/体征/报告的归属可见路径接入模块闸门 + 企业范围
DROP POLICY IF EXISTS "Managers can view client records via relation" ON public.health_records;
CREATE POLICY "Managers can view client records via relation" ON public.health_records
  FOR SELECT USING (
    public.module_open_for_client(health_records.user_id, 'view_health_records')
    AND public.can_manager_view_client_category(health_records.user_id, 'share_records')
  );

DROP POLICY IF EXISTS "Managers can view client vitals via relation" ON public.vital_signs;
CREATE POLICY "Managers can view client vitals via relation" ON public.vital_signs
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.health_records hr
      WHERE hr.id = vital_signs.record_id
        AND public.module_open_for_client(hr.user_id, 'view_health_records')
        AND public.can_manager_view_client_category(hr.user_id, 'share_vitals')
    )
  );

DROP POLICY IF EXISTS "manager_can_select_via_client_relation" ON public.medical_reports;
CREATE POLICY "manager_can_select_via_client_relation" ON public.medical_reports
  FOR SELECT USING (
    public.module_open_for_client(medical_reports.user_id, 'view_health_records')
    AND public.can_manager_view_client_category(medical_reports.user_id, 'data_analysis')
  );

-- 存量商户迁移：全部授予并开启 view_health_records，保持既有档案/报告可见能力不回退
-- 新注册商户没有这行，默认全关，由平台逐个授予
INSERT INTO public.merchant_module_grants (manager_id, module_key, grant_status, is_enabled, notes)
SELECT m.id, 'view_health_records', 'granted', true, '存量迁移：保持既有档案/报告可见能力'
FROM public.managers m
ON CONFLICT (manager_id, module_key) DO NOTHING;