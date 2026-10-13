-- 将所有卡在 parsing 状态的报告改为 failed，让用户可以重新操作
UPDATE public.medical_reports
SET status = 'failed',
    ai_summary = '解析超时，请重新上传报告',
    updated_at = now()
WHERE status = 'parsing';