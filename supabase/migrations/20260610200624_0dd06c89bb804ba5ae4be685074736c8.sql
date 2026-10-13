UPDATE manager_knowledge_documents
SET status = 'failed',
    error_message = 'V1 inline 旧版文档，请重新上传或在「立即训练」中重建',
    updated_at = now()
WHERE backend = 'kqa'
  AND status <> 'failed';