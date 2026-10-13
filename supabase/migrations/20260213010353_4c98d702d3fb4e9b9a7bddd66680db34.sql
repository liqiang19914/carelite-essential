
-- 病史变更日志表：记录健康档案中病史字段的历史变更
CREATE TABLE IF NOT EXISTS medical_history_logs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  record_id UUID NOT NULL REFERENCES health_records(id) ON DELETE CASCADE,
  field_name TEXT NOT NULL,  -- 'medical_history', 'allergy_history', 'surgery_history', 'medication_history'
  old_value TEXT,
  new_value TEXT NOT NULL,
  changed_at TIMESTAMPTZ DEFAULT now() NOT NULL
);

CREATE INDEX idx_medical_history_logs_record_id ON medical_history_logs(record_id);
CREATE INDEX idx_medical_history_logs_changed_at ON medical_history_logs(changed_at DESC);

COMMENT ON TABLE medical_history_logs IS '病史变更日志表，记录健康档案中病史字段的每次修改';
COMMENT ON COLUMN medical_history_logs.field_name IS '变更的字段名：medical_history/allergy_history/surgery_history/medication_history';
