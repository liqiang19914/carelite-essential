-- 455 店铺装修审核模式：审核菜单草稿/发布双态列 + 启用开关（幂等）
ALTER TABLE public.merchant_shop_configs
  ADD COLUMN IF NOT EXISTS draft_review_navigation jsonb,
  ADD COLUMN IF NOT EXISTS published_review_navigation jsonb,
  ADD COLUMN IF NOT EXISTS review_menu_enabled boolean NOT NULL DEFAULT false;

-- 456 游客问问AI落地路径：商户接待智能体解析链（343 群链接承接智能体 → managers.short_code）
-- 仅内部与 Edge Function(service_role) 使用：公开/登录角色一律收回执行权
CREATE OR REPLACE FUNCTION public.resolve_merchant_guest_chat_path(p_root uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT '/m/' || COALESCE(NULLIF(btrim(m.short_code), ''), m.id::text) || '/consult'
  FROM public.merchant_wecom_settings s
  JOIN public.managers m ON m.id = s.agent_manager_id
  WHERE s.root_manager_id = p_root
    AND s.agent_manager_id IS NOT NULL
  LIMIT 1
$function$;

REVOKE EXECUTE ON FUNCTION public.resolve_merchant_guest_chat_path(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_merchant_guest_chat_path(uuid) TO service_role;