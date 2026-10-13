-- Microsoft Clarity 官网行为统计：项目 ID 不是密钥，浏览器必须读取它来加载官方脚本。
-- 仅把这一个非敏感键加入公开白名单；system_settings 里的其他凭据仍保持管理员可见。

CREATE OR REPLACE FUNCTION public._is_public_system_setting(p_key text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT p_key IN (
    'miniapp_brand_name',
    'miniapp_brand_logo_url',
    'miniapp_brand_primary_color',
    'miniapp_ai_agent_name',
    'miniapp_brand_full_name',
    'miniapp_privacy_policy_url',
    'miniapp_terms_url',
    'miniapp_support_contact',
    'miniapp_shop_banner',
    'domain_user',
    'display_live_enabled',
    'display_private_butler_enabled',
    'display_verification_enabled',
    'clarity_project_id'
  );
$$;

COMMENT ON FUNCTION public._is_public_system_setting(text) IS
  'system_settings 的公开键白名单。Clarity 项目 ID 是浏览器端公开标识，不是账号密钥；其他第三方凭据不得加入。';

INSERT INTO public.system_settings (key, value, description)
VALUES (
  'clarity_project_id',
  'ybear8vo9o',
  'Microsoft Clarity 官网行为统计项目 ID（公开标识，清空即停用）'
)
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value,
    description = EXCLUDED.description,
    updated_at = now();
