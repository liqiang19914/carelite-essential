-- 为体征数据表添加备注字段
ALTER TABLE vital_signs
ADD COLUMN IF NOT EXISTS notes TEXT;