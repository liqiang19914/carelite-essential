-- medical_reports:两条 manager 分支 policy 都加 data_analysis 阀门。
-- owner 分支 (Users can view own medical reports) 与 admin 分支 (admin_select_all_medical_reports) 不动。
DROP POLICY IF EXISTS "manager_can_select_via_client_relation" ON public.medical_reports;
CREATE POLICY "manager_can_select_via_client_relation"
  ON public.medical_reports
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.client_relations cr
      WHERE cr.manager_id = auth.uid()
        AND cr.client_id = medical_reports.user_id
        AND cr.status::text = 'active'
    )
    AND public.can_manager_view_client_category(medical_reports.user_id, 'data_analysis')
  );

DROP POLICY IF EXISTS "manager_can_select_via_record_authorization" ON public.medical_reports;
CREATE POLICY "manager_can_select_via_record_authorization"
  ON public.medical_reports
  FOR SELECT
  USING (
    record_id IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.record_authorizations a
      WHERE a.manager_id = auth.uid()
        AND a.is_active = true
        AND a.record_id = medical_reports.record_id
    )
    AND public.can_manager_view_client_category(medical_reports.user_id, 'data_analysis')
  );

-- report_interpretations:两条 manager 分支同上加阀门。
DROP POLICY IF EXISTS "manager_can_select_via_client_relation" ON public.report_interpretations;
CREATE POLICY "manager_can_select_via_client_relation"
  ON public.report_interpretations
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.client_relations cr
      WHERE cr.manager_id = auth.uid()
        AND cr.client_id = report_interpretations.user_id
        AND cr.status::text = 'active'
    )
    AND public.can_manager_view_client_category(report_interpretations.user_id, 'data_analysis')
  );

DROP POLICY IF EXISTS "manager_can_select_via_record_authorization" ON public.report_interpretations;
CREATE POLICY "manager_can_select_via_record_authorization"
  ON public.report_interpretations
  FOR SELECT
  USING (
    record_id IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.record_authorizations a
      WHERE a.manager_id = auth.uid()
        AND a.is_active = true
        AND a.record_id = report_interpretations.record_id
    )
    AND public.can_manager_view_client_category(report_interpretations.user_id, 'data_analysis')
  );

-- report_comparisons:两条 manager 分支同上加阀门(注意阀门参数是 report_comparisons.user_id)。
DROP POLICY IF EXISTS "manager_can_select_via_client_relation" ON public.report_comparisons;
CREATE POLICY "manager_can_select_via_client_relation"
  ON public.report_comparisons
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.client_relations cr
      WHERE cr.manager_id = auth.uid()
        AND cr.client_id = report_comparisons.user_id
        AND cr.status::text = 'active'
    )
    AND public.can_manager_view_client_category(report_comparisons.user_id, 'data_analysis')
  );

DROP POLICY IF EXISTS "manager_can_select_via_record_authorization" ON public.report_comparisons;
CREATE POLICY "manager_can_select_via_record_authorization"
  ON public.report_comparisons
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.medical_reports mr_older
      JOIN public.medical_reports mr_newer ON mr_newer.id = report_comparisons.report_newer_id
      WHERE mr_older.id = report_comparisons.report_older_id
        AND EXISTS (
          SELECT 1 FROM public.record_authorizations a
          WHERE a.manager_id = auth.uid()
            AND a.is_active = true
            AND a.record_id = mr_older.record_id
        )
        AND EXISTS (
          SELECT 1 FROM public.record_authorizations a
          WHERE a.manager_id = auth.uid()
            AND a.is_active = true
            AND a.record_id = mr_newer.record_id
        )
    )
    AND public.can_manager_view_client_category(report_comparisons.user_id, 'data_analysis')
  );

-- exercise_logs:manager select policy 加 share_vitals 阀门(生活方式类打卡数据受体征开关统一控制)。
DROP POLICY IF EXISTS "Managers can view client exercise logs" ON public.exercise_logs;
CREATE POLICY "Managers can view client exercise logs"
  ON public.exercise_logs
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.client_relations cr
      WHERE cr.client_id = exercise_logs.user_id
        AND cr.manager_id = auth.uid()
        AND cr.status::text = 'active'
    )
    AND public.can_manager_view_client_category(exercise_logs.user_id, 'share_vitals')
  );

-- mood_logs:同上,manager select policy 加 share_vitals 阀门。
DROP POLICY IF EXISTS "Managers can view client mood logs" ON public.mood_logs;
CREATE POLICY "Managers can view client mood logs"
  ON public.mood_logs
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.client_relations cr
      WHERE cr.manager_id = auth.uid()
        AND cr.client_id = mood_logs.user_id
        AND cr.status::text = 'active'
    )
    AND public.can_manager_view_client_category(mood_logs.user_id, 'share_vitals')
  );