-- 报告 AI 解析开关：默认关闭。
-- 开源版默认不内置视觉模型网关；管理员在「系统设置 → AI 服务」开启后才在上传时触发解析。
-- 该键加入公开白名单：C 端上传前需要读取它决定是否走解析链路（非密钥）。

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
    'clarity_project_id',
    'report_ai_parse_enabled'
  );
$$;

COMMENT ON FUNCTION public._is_public_system_setting(text) IS
  'system_settings 的公开键白名单。仅限浏览器端必须读取的非敏感键。';

INSERT INTO public.system_settings (key, value, description)
VALUES (
  'report_ai_parse_enabled',
  'false',
  '体检报告 AI 解析开关（需自备视觉模型 API；关闭时上传仅存档不解析）'
)
ON CONFLICT (key) DO UPDATE
SET description = EXCLUDED.description,
    updated_at = now();
