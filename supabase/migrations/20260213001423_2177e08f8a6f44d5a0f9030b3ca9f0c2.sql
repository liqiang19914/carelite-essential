
-- 体检报告表
CREATE TABLE IF NOT EXISTS medical_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  record_id UUID REFERENCES health_records(id) ON DELETE SET NULL,
  title VARCHAR(200) NOT NULL DEFAULT '体检报告',
  hospital VARCHAR(200) DEFAULT '',
  report_date DATE,
  file_url TEXT NOT NULL,
  file_type VARCHAR(20) NOT NULL DEFAULT 'pdf',
  file_size INTEGER DEFAULT 0,
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  total_items INTEGER DEFAULT 0,
  abnormal_items INTEGER DEFAULT 0,
  ai_summary TEXT DEFAULT '',
  parsed_data JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_medical_reports_user_id ON medical_reports(user_id);
CREATE INDEX IF NOT EXISTS idx_medical_reports_record_id ON medical_reports(record_id);

COMMENT ON TABLE medical_reports IS '体检报告表，存储用户上传的体检报告及AI解析结果';
