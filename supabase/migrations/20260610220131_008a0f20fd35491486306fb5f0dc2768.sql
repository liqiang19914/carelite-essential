ALTER TABLE managers
  ADD COLUMN IF NOT EXISTS knowledge_category_id TEXT;

COMMENT ON COLUMN managers.knowledge_category_id IS '百炼数据中心一人一文件夹的 CategoryId，懒建于首次训练 / 首次上传';