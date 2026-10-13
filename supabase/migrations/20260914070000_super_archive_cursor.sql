-- 消息归档（/msg/syncMsg）拉取游标持久化：
-- 中断/关页后再次点击「修复历史消息」从上次位置继续；拉平后后续调用为增量。
ALTER TABLE public.wecom_super_merchant_config
  ADD COLUMN IF NOT EXISTS archive_cursor bigint NOT NULL DEFAULT 0;
