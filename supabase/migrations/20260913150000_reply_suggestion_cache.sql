-- Task 6: 推荐话术 5 分钟缓存支撑
-- Edge Function 多实例部署，进程内 Map 不共享；以日志表 last_msgid 作为缓存键查最近生成结果。
ALTER TABLE public.wecom_reply_suggestion_logs
  ADD COLUMN IF NOT EXISTS last_msgid text;

-- 缓存命中查询：同租户/同会话/同末条消息，按时间倒序
CREATE INDEX IF NOT EXISTS idx_wecom_reply_logs_cache
  ON public.wecom_reply_suggestion_logs (
    root_manager_id, roomid, created_at DESC
  )
  WHERE suggestions IS NOT NULL;

NOTIFY pgrst, 'reload schema';
