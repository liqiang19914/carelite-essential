-- 体检报告对比缓存表
CREATE TABLE report_comparisons (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  report_older_id UUID NOT NULL REFERENCES medical_reports(id) ON DELETE CASCADE,
  report_newer_id UUID NOT NULL REFERENCES medical_reports(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','generating','ready','failed')),
  summary TEXT NOT NULL DEFAULT '',
  improvement_score SMALLINT,
  deltas JSONB NOT NULL DEFAULT '[]'::jsonb,
  highlights JSONB NOT NULL DEFAULT '[]'::jsonb,
  ai_comment TEXT NOT NULL DEFAULT '',
  model_used TEXT NOT NULL DEFAULT '',
  error_message TEXT NOT NULL DEFAULT '',
  generated_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, report_older_id, report_newer_id)
);

COMMENT ON TABLE report_comparisons IS '体检报告对比结果缓存表，存储 AI 生成的 A vs B 报告对比与评语';
COMMENT ON COLUMN report_comparisons.improvement_score IS '改善分数，-100 (恶化) ~ +100 (大幅改善)';
COMMENT ON COLUMN report_comparisons.deltas IS '机械计算的指标差异数组 [{name, value_a, value_b, delta, direction, is_good}]';
COMMENT ON COLUMN report_comparisons.highlights IS '关键变化亮点 [{label, content, severity}]';

CREATE INDEX idx_report_comparisons_user_id ON report_comparisons(user_id);
CREATE INDEX idx_report_comparisons_older ON report_comparisons(report_older_id);
CREATE INDEX idx_report_comparisons_newer ON report_comparisons(report_newer_id);