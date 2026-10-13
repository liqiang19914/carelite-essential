-- 1.B.2.A 触发器活体测试 — 已在原始 session 验证通过(3 场景全 PASS)。
-- 原始 DO 块会临时修改一个 platform product 然后还原,但即使幂等也会触发 updated_at
-- 与 Realtime 推送。重跑这条迁移无任何业务意义,因此中和为 no-op。
--
-- 验证留痕:
-- - 场景 1:UPDATE products SET cover_image_url='...' → cover_images[0] 同步成功
-- - 场景 2:UPDATE products SET cover_images='[A,B,C]' → cover_image_url=A 同步成功
-- - 场景 3:UPDATE products SET cover_images='[]' → cover_image_url='' 同步成功
SELECT 1 AS shop_cover_mirror_trigger_verified;
