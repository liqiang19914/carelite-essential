-- 推荐话术：区分「客户待回复 / 员工待跟进」两种生成模式，缓存与日志按模式隔离
ALTER TABLE public.wecom_reply_suggestion_logs
  ADD COLUMN IF NOT EXISTS awaiting_reply boolean;

NOTIFY pgrst, 'reload schema';
