-- 知识库上传失败可恢复（feature 471）：解析重试基准 + 兜底入库来源标记
ALTER TABLE public.manager_knowledge_documents
  ADD COLUMN IF NOT EXISTS last_retry_at timestamp with time zone,
  ADD COLUMN IF NOT EXISTS content_source text;

COMMENT ON COLUMN public.manager_knowledge_documents.last_retry_at IS
  '用户最近一次点「重试」重新提交解析的时间。解析超时判定以它（其次 created_at）为基准，避免老文档重试后被秒判超时。';
COMMENT ON COLUMN public.manager_knowledge_documents.content_source IS
  '入库内容来源：NULL/native=原文件解析；text_extract=Word 正文文字本地兜底提取后入库。';