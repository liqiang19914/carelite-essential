-- 知识库文档诊断/幂等列扩展
-- 目标：支撑分阶段错因、超时降级、幂等重试

ALTER TABLE public.manager_knowledge_documents
  ADD COLUMN IF NOT EXISTS error_stage TEXT NULL,
  ADD COLUMN IF NOT EXISTS error_code TEXT NULL,
  ADD COLUMN IF NOT EXISTS bailian_raw_status TEXT NULL,
  ADD COLUMN IF NOT EXISTS bailian_job_id TEXT NULL,
  ADD COLUMN IF NOT EXISTS last_polled_at TIMESTAMPTZ NULL,
  ADD COLUMN IF NOT EXISTS poll_count INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS client_idem_key TEXT NULL;

-- 部分唯一索引：同一 manager 下相同 idem_key 只能有一条 doc（用于前端幂等重试短路）
CREATE UNIQUE INDEX IF NOT EXISTS manager_knowledge_documents_idem_key_uniq
  ON public.manager_knowledge_documents (manager_id, client_idem_key)
  WHERE client_idem_key IS NOT NULL;

COMMENT ON COLUMN public.manager_knowledge_documents.error_stage IS
  '失败阶段：upload | submit | parse | index（parse=百炼 DocMind 解析阶段；index=索引构建阶段）';
COMMENT ON COLUMN public.manager_knowledge_documents.error_code IS
  '错误码（百炼 error code 或本地 sentinel，如 parse_timeout）';
COMMENT ON COLUMN public.manager_knowledge_documents.bailian_raw_status IS
  '百炼 DescribeFile 返回的原始 Status（INIT/PARSING/PARSE_SUCCESS/PARSE_FAILED），诊断用';
COMMENT ON COLUMN public.manager_knowledge_documents.bailian_job_id IS
  'SubmitIndexJob 返回的 JobId，用于跨会话追踪索引构建进度';
COMMENT ON COLUMN public.manager_knowledge_documents.last_polled_at IS
  '最近一次对百炼真实态回查的时间（DescribeFile 调用时间）';
COMMENT ON COLUMN public.manager_knowledge_documents.poll_count IS
  '累计回查次数；用于配合创建时长阈值触发解析超时降级';
COMMENT ON COLUMN public.manager_knowledge_documents.client_idem_key IS
  '前端上传时生成的幂等键（UUID），用于重试短路避免百炼侧重复上传';