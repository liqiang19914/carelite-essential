-- One-time backfill: reconcile 4 stuck/incomplete manager knowledge docs for manager ab64a9d1 
-- based on real Bailian DescribeFile responses gathered 2026-07-22.

-- 1) [系统] 健康管理师档案 — Bailian says PARSE_SUCCESS
UPDATE public.manager_knowledge_documents
SET status = 'ready',
    error_message = NULL,
    error_stage = NULL,
    error_code = NULL,
    bailian_raw_status = 'PARSE_SUCCESS',
    last_polled_at = NOW(),
    poll_count = COALESCE(poll_count, 0) + 1,
    updated_at = NOW()
WHERE id = '63164286-3453-457c-af5a-5016426b1830';

-- 2) [系统] 课程目录大纲 — Bailian says PARSE_SUCCESS
UPDATE public.manager_knowledge_documents
SET status = 'ready',
    error_message = NULL,
    error_stage = NULL,
    error_code = NULL,
    bailian_raw_status = 'PARSE_SUCCESS',
    last_polled_at = NOW(),
    poll_count = COALESCE(poll_count, 0) + 1,
    updated_at = NOW()
WHERE id = '1889bb16-17d0-44af-be55-41bf0303530c';

-- 3) [系统] 客户绑定指引 — Bailian says PARSE_SUCCESS
UPDATE public.manager_knowledge_documents
SET status = 'ready',
    error_message = NULL,
    error_stage = NULL,
    error_code = NULL,
    bailian_raw_status = 'PARSE_SUCCESS',
    last_polled_at = NOW(),
    poll_count = COALESCE(poll_count, 0) + 1,
    updated_at = NOW()
WHERE id = '3c251cc8-65ec-4442-bbca-9eb8ffaac226';

-- 4) 教育程度.xls — Bailian confirms PARSE_FAILED with a real error message about legacy .xls format
UPDATE public.manager_knowledge_documents
SET status = 'failed',
    error_message = '百炼文档解析失败：ElectronicParsingError（旧版 .xls 格式常见）。建议用 Office 打开后「另存为」xlsx，再重新上传。',
    error_stage = 'parse',
    error_code = 'ElectronicParsingError',
    bailian_raw_status = 'PARSE_FAILED',
    last_polled_at = NOW(),
    poll_count = COALESCE(poll_count, 0) + 1,
    updated_at = NOW()
WHERE id = '7089cb84-9f4c-4a16-a9dd-3ea8d2189aa0';

-- 5) Reconcile the manager's top-level knowledge_index_status per the new ≥1 ready rule
UPDATE public.managers
SET knowledge_index_status = 'ready',
    updated_at = NOW()
WHERE id = 'ab64a9d1-45b0-4d93-9b95-54a5feb11d5d'
  AND EXISTS (
    SELECT 1 FROM public.manager_knowledge_documents
    WHERE manager_id = 'ab64a9d1-45b0-4d93-9b95-54a5feb11d5d'
      AND status = 'ready'
  );