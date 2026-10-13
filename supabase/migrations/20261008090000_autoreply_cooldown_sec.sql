-- 自动回复：冷却时间从「分钟」精度升级到「秒」级（最低 20 秒），
-- 并新增「跨对象消息间隔」字段（最低 5 秒，给 A 发完到给 B 发的最小间隔）。
-- 旧 ar_cooldown_min 保留作为兼容回退；新逻辑读 ar_cooldown_sec。

ALTER TABLE public.wecom_super_devices
  ADD COLUMN IF NOT EXISTS ar_cooldown_sec int NOT NULL DEFAULT 120,
  ADD COLUMN IF NOT EXISTS ar_cross_object_interval_sec int NOT NULL DEFAULT 30;

-- 数据迁移：把旧「分钟」值转成「秒」（× 60），仅对新列为默认值 120（即原默认 2 分钟）的行执行
UPDATE public.wecom_super_devices
  SET ar_cooldown_sec = GREATEST(20, ar_cooldown_min * 60)
  WHERE ar_cooldown_sec = 120 AND ar_cooldown_min IS NOT NULL AND ar_cooldown_min * 60 >= 20;

-- 同样在商户级 config 表加同名字段（device.updateAutoreplyConfig 也写商户级 fallback）
ALTER TABLE public.wecom_super_merchant_config
  ADD COLUMN IF NOT EXISTS autoreply_cooldown_sec int NOT NULL DEFAULT 120,
  ADD COLUMN IF NOT EXISTS autoreply_cross_object_interval_sec int NOT NULL DEFAULT 30;

UPDATE public.wecom_super_merchant_config
  SET autoreply_cooldown_sec = GREATEST(20, autoreply_cooldown_min * 60)
  WHERE autoreply_cooldown_sec = 120 AND autoreply_cooldown_min IS NOT NULL
    AND autoreply_cooldown_min * 60 >= 20;

COMMENT ON COLUMN public.wecom_super_devices.ar_cooldown_sec IS
  '同一对象自动回复冷却（秒），最小 20，默认 120；同一 peer 在冷却内不重复自动回复';
COMMENT ON COLUMN public.wecom_super_devices.ar_cross_object_interval_sec IS
  '跨对象消息间隔（秒），最小 5，默认 30；给 A 发完后给 B 发的最小间隔，防止高频并发触发风控';
