-- Supabase 对 public schema 的新函数默认会显式授予 anon/authenticated，
-- 只 REVOKE FROM PUBLIC 收不掉，必须按角色逐个收回。
REVOKE EXECUTE ON FUNCTION public._mask_person_name(text) FROM anon;
REVOKE EXECUTE ON FUNCTION public._mask_phone(text) FROM anon;

-- 这两个是 SECURITY DEFINER 的内部助手：直接暴露给前端等于允许枚举企业成员 id，
-- 只能由同样 SECURITY DEFINER 的对外 RPC 以属主身份调用。
REVOKE EXECUTE ON FUNCTION public._resolve_manager_scope(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public._resolve_manager_scope(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public._manager_visible_owner_ids(uuid, uuid, boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION public._manager_visible_owner_ids(uuid, uuid, boolean) FROM authenticated;

-- 对外的两个 RPC 自己做登录与归属校验，匿名调用没有任何意义，直接关掉
REVOKE EXECUTE ON FUNCTION public.manager_list_shop_orders(text[], text, timestamptz, uuid, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.manager_get_shop_order(text) FROM anon;