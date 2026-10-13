-- 验收结束：恢复韩老师 public_qa_enabled，并清理 drill 演练数据
UPDATE public.managers SET public_qa_enabled = TRUE WHERE id = 'a6f5c22f-33ec-411f-ad26-3777ebbb534e';

DELETE FROM public.manager_public_qa_sessions
WHERE visitor_token IN ('pqa_rate_limit_drill', 'pqa_token_drill');