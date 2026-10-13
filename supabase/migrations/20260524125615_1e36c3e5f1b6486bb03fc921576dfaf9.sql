-- AI 体检报告解读缓存表
CREATE TABLE report_interpretations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id UUID NOT NULL UNIQUE REFERENCES medical_reports(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  record_id UUID,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','generating','ready','failed')),
  summary TEXT NOT NULL DEFAULT '',
  focus_points JSONB NOT NULL DEFAULT '[]'::jsonb,
  lifestyle JSONB NOT NULL DEFAULT '{}'::jsonb,
  recheck JSONB NOT NULL DEFAULT '{}'::jsonb,
  ai_comment TEXT NOT NULL DEFAULT '',
  model_used TEXT NOT NULL DEFAULT '',
  error_message TEXT NOT NULL DEFAULT '',
  generated_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE report_interpretations IS 'AI 体检报告解读缓存表，按 report_id 单表幂等';
COMMENT ON COLUMN report_interpretations.summary IS '一句话整体结论（≤ 40 字）';
COMMENT ON COLUMN report_interpretations.focus_points IS '关注重点列表 [{name, current_value, status, comment}]';
COMMENT ON COLUMN report_interpretations.lifestyle IS '生活建议 {diet, exercise, sleep, mindset}';
COMMENT ON COLUMN report_interpretations.recheck IS '复查建议 {interval, items, note}';
COMMENT ON COLUMN report_interpretations.ai_comment IS '综合 AI 医师评语 markdown';

CREATE INDEX idx_report_interpretations_user_id ON report_interpretations(user_id);
CREATE INDEX idx_report_interpretations_record_id ON report_interpretations(record_id);

ALTER TABLE report_interpretations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "owner_can_select_own_interpretation" ON report_interpretations
  FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "manager_can_select_via_client_relation" ON report_interpretations
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM client_relations cr
      WHERE cr.manager_id = auth.uid()
        AND cr.client_id = report_interpretations.user_id
        AND cr.status = 'active'
    )
  );

CREATE POLICY "manager_can_select_via_record_authorization" ON report_interpretations
  FOR SELECT
  USING (
    report_interpretations.record_id IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM record_authorizations a
      WHERE a.manager_id = auth.uid()
        AND a.is_active = true
        AND a.record_id = report_interpretations.record_id
    )
  );

CREATE POLICY "admin_can_select_all_interpretations" ON report_interpretations
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles p
      WHERE p.id = auth.uid()
        AND p.role = 'admin'
    )
  );

-- 写入仅由 SERVICE_ROLE 边缘函数完成，自动绕过 RLS
