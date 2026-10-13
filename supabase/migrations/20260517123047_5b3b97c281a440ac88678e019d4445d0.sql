-- 为 report_comparisons 添加 RLS 策略
ALTER TABLE report_comparisons ENABLE ROW LEVEL SECURITY;

-- 用户本人可查看自己的对比
CREATE POLICY "owner_can_select_own_comparison" ON report_comparisons
  FOR SELECT
  USING (auth.uid() = user_id);

-- 管理师通过 client_relations 绑定可查看其客户的对比
CREATE POLICY "manager_can_select_via_client_relation" ON report_comparisons
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM client_relations cr
      WHERE cr.manager_id = auth.uid()
        AND cr.client_id = report_comparisons.user_id
        AND cr.status = 'active'
    )
  );

-- 管理师通过 record_authorizations 授权且对比涉及的两份报告 record_id 都已授权时可查看
CREATE POLICY "manager_can_select_via_record_authorization" ON report_comparisons
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM medical_reports mr_older
      JOIN medical_reports mr_newer ON mr_newer.id = report_comparisons.report_newer_id
      WHERE mr_older.id = report_comparisons.report_older_id
        AND EXISTS (
          SELECT 1 FROM record_authorizations a
          WHERE a.manager_id = auth.uid()
            AND a.is_active = true
            AND a.record_id = mr_older.record_id
        )
        AND EXISTS (
          SELECT 1 FROM record_authorizations a
          WHERE a.manager_id = auth.uid()
            AND a.is_active = true
            AND a.record_id = mr_newer.record_id
        )
    )
  );

-- 后台管理员可查看全部对比
CREATE POLICY "admin_can_select_all_comparisons" ON report_comparisons
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles p
      WHERE p.id = auth.uid()
        AND p.role = 'admin'
    )
  );

-- 注：写入由 SERVICE_ROLE 边缘函数完成，自动绕过 RLS；不放开任何 INSERT/UPDATE/DELETE 给 anon