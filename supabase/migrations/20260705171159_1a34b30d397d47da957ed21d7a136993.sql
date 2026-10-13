-- 1. conversations 增加 record_id（对话绑定的家庭成员档案）
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS record_id UUID REFERENCES health_records(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_conversations_user_agent_record_updated
  ON conversations(user_id, agent_id, record_id, updated_at DESC);

-- record_id 写入时必须为空或属于当前用户自己的健康档案
ALTER POLICY "Users can create own conversations" ON conversations
  WITH CHECK (
    auth.uid() = user_id
    AND (record_id IS NULL OR EXISTS (
      SELECT 1 FROM health_records hr WHERE hr.id = record_id AND hr.user_id = auth.uid()
    ))
  );

ALTER POLICY "Users can update own conversations" ON conversations
  USING (auth.uid() = user_id)
  WITH CHECK (
    auth.uid() = user_id
    AND (record_id IS NULL OR EXISTS (
      SELECT 1 FROM health_records hr WHERE hr.id = record_id AND hr.user_id = auth.uid()
    ))
  );

-- 2. medical_reports 补齐 RLS（该表此前 RLS 未启用，任何 anon key 请求理论上都能读写任意用户的报告行）
ALTER TABLE medical_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own medical reports" ON medical_reports
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own medical reports" ON medical_reports
  FOR INSERT WITH CHECK (
    auth.uid() = user_id
    AND (record_id IS NULL OR EXISTS (
      SELECT 1 FROM health_records hr WHERE hr.id = record_id AND hr.user_id = auth.uid()
    ))
  );

CREATE POLICY "Users can update own medical reports" ON medical_reports
  FOR UPDATE USING (auth.uid() = user_id)
  WITH CHECK (
    auth.uid() = user_id
    AND (record_id IS NULL OR EXISTS (
      SELECT 1 FROM health_records hr WHERE hr.id = record_id AND hr.user_id = auth.uid()
    ))
  );

CREATE POLICY "Users can delete own medical reports" ON medical_reports
  FOR DELETE USING (auth.uid() = user_id);

CREATE POLICY "manager_can_select_via_client_relation" ON medical_reports
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM client_relations cr
      WHERE cr.manager_id = auth.uid()
        AND cr.client_id = medical_reports.user_id
        AND cr.status = 'active'
    )
  );

CREATE POLICY "manager_can_select_via_record_authorization" ON medical_reports
  FOR SELECT USING (
    medical_reports.record_id IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM record_authorizations a
      WHERE a.manager_id = auth.uid()
        AND a.is_active = true
        AND a.record_id = medical_reports.record_id
    )
  );

CREATE POLICY "admin_select_all_medical_reports" ON medical_reports
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.role = 'admin'
    )
  );

-- 3. 报告排序 + 归属查询用的复合索引
CREATE INDEX IF NOT EXISTS idx_medical_reports_user_report_date_created
  ON medical_reports(user_id, report_date DESC, created_at DESC);

-- 4. 报告转移归属 RPC：同事务内校验双方归属并同步解读缓存的 record_id
CREATE OR REPLACE FUNCTION public.transfer_medical_report_record(
  p_report_id UUID,
  p_target_record_id UUID
)
RETURNS medical_reports
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_report medical_reports%ROWTYPE;
  v_target_owner UUID;
BEGIN
  SELECT user_id INTO v_target_owner
  FROM health_records
  WHERE id = p_target_record_id;

  IF v_target_owner IS NULL OR v_target_owner <> auth.uid() THEN
    RAISE EXCEPTION '无权使用该健康档案';
  END IF;

  PERFORM 1 FROM medical_reports
  WHERE id = p_report_id AND user_id = auth.uid()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '无权转移该报告';
  END IF;

  UPDATE medical_reports
  SET record_id = p_target_record_id, updated_at = now()
  WHERE id = p_report_id
  RETURNING * INTO v_report;

  UPDATE report_interpretations
  SET record_id = p_target_record_id
  WHERE report_id = p_report_id;

  RETURN v_report;
END;
$function$;

REVOKE ALL ON FUNCTION public.transfer_medical_report_record(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.transfer_medical_report_record(UUID, UUID) TO authenticated;