-- 支付快照表 wechat_miniapp_pay_orders 上遗留着 anon / authenticated 的全量表权限
-- （SELECT/INSERT/UPDATE/DELETE/TRUNCATE）。现在靠「开了 RLS 但没有任何策略 = 全拒」挡住，
-- 但只要将来任何人给这张表加一条策略，写权限就会立刻对匿名访客敞开。
--
-- 前端没有任何代码直连这张表（全部走 SECURITY DEFINER 函数与 Edge Function），
-- 所以收权限是行为中性的，只是把这个坑填掉。
REVOKE ALL ON TABLE public.wechat_miniapp_pay_orders FROM anon;
REVOKE ALL ON TABLE public.wechat_miniapp_pay_orders FROM authenticated;
GRANT ALL ON TABLE public.wechat_miniapp_pay_orders TO service_role;