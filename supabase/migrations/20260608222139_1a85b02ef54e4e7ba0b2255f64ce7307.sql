-- 知识库文档新增 content_text 字段，存放从文件提取的可检索文本（V1 走 inline 拼 prompt 路径，硬行级隔离）
ALTER TABLE manager_knowledge_documents
  ADD COLUMN IF NOT EXISTS content_text TEXT;

COMMENT ON COLUMN manager_knowledge_documents.content_text IS 'V1 inline 路径：从文件解析得到的纯文本，用于 manager-knowledge-qa EF 拼入 system prompt。后续可平替到百炼 index_id 路径。';