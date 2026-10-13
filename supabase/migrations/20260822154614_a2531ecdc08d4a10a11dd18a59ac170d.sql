-- 清理 manager_create_product 旧签名（11 参、无 store_only），避免同名重载歧义
DROP FUNCTION IF EXISTS public.manager_create_product(text, text, text, text, jsonb, jsonb, text, text[], text, integer, text, jsonb);