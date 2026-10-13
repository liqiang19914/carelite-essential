-- 幂等第 1 层：同一档案下的 idempotency_key 唯一。
-- 原来只有 自然键 / provider_measurement_id / fingerprint 三层唯一索引，
-- idempotency_key 只是普通列，靠代码预查会有并发窗口，这里交给数据库兜住。
CREATE UNIQUE INDEX IF NOT EXISTS body_compositions_idempotency_key
  ON public.body_compositions (record_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;