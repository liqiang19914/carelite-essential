
-- 1.B.1 Hotfix：mark_order_paid/refunded_from_gateway 仅 service_role 可调
-- 之前 REVOKE FROM PUBLIC 不够：Supabase 的 anon/authenticated 是从 public 继承外
-- 还独立显式被授予了某些权限（且 PG 函数默认是 PUBLIC 可调用）。
REVOKE ALL ON FUNCTION public.mark_order_paid_from_gateway(TEXT, TEXT, INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_order_paid_from_gateway(TEXT, TEXT, INTEGER, TEXT) TO service_role;

REVOKE ALL ON FUNCTION public.mark_order_refunded_from_gateway(TEXT, INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_order_refunded_from_gateway(TEXT, INTEGER, TEXT) TO service_role;
