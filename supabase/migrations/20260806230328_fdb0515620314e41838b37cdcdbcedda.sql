-- ============================================================================
-- 安全修复（紧急）：关闭匿名可读写的两张关键表
--
-- 已实测确认（用前端公开的 anon key 直连 REST）：
--   1) sms_verifications 匿名可读，返回 {"phone":"150****0150","code":"******"}
--      —— 任何人可为任意手机号请求验证码后直接读出，等于可登录任意账号；且可匿名写入。
--   2) system_settings 匿名可读全部 91 行并可匿名 INSERT/DELETE（已用探针键验证并清理），
--      其中包含 alipay_private_key / wechat_app_secret / wechat_native_*_secret /
--      wxpay_api_key / wxpay_api_v3_key / oss_access_key_secret / sms_access_key_secret /
--      bailian_access_key_secret / dashscope_api_key / miniapp_appsecret 等第三方凭证。
--
-- 成因：两表均未启用行级安全，且 anon / authenticated 持有全量表级权限。
-- 处置原则：服务端（service_role）访问不受影响；前端只保留其确实在用的最小面。
-- 已逐一核对前端调用点后再收权，不做超出现有用法的收紧。
-- ============================================================================


-- ─────────────────────────────────────────────────────────────
-- 一、sms_verifications：前端零访问，只由短信 Edge Function 读写
--     （已确认 src/ 下没有任何引用）→ 直接收回全部客户端权限
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.sms_verifications ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.sms_verifications FROM anon;
REVOKE ALL ON TABLE public.sms_verifications FROM authenticated;
GRANT ALL ON TABLE public.sms_verifications TO service_role;

COMMENT ON TABLE public.sms_verifications IS
  '短信验证码。仅 service_role 可访问：验证码是明文，任何客户端可读即等于可登录任意账号。禁止为 anon / authenticated 添加任何策略或授权。';


-- ─────────────────────────────────────────────────────────────
-- 二、reminders：前端零访问，只由服务端提醒逻辑读写
--     （已确认 src/ 下没有任何引用）→ 直接收回全部客户端权限
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.reminders ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.reminders FROM anon;
REVOKE ALL ON TABLE public.reminders FROM authenticated;
GRANT ALL ON TABLE public.reminders TO service_role;


-- ─────────────────────────────────────────────────────────────
-- 三、system_settings：启用行级安全
--     前端真实用法只有三处，逐一对应：
--       a) BrandContext → fetchPlatformBrand()：未登录状态要读 8 个品牌键
--       b) useConfiguredDomain：读 domain_user 生成分享链接（非密钥）
--       c) 5 个后台配置页（微信登录/系统/小程序/RAG/龙虾）：全表读写，仅管理员
--     所有 Edge Function 读配置用的都是 service_role 客户端（已抽查确认），不受影响。
-- ─────────────────────────────────────────────────────────────

-- 公开键白名单。注意：miniapp_appid / miniapp_appsecret / miniapp_upload_key
-- 同样是 miniapp_ 前缀但属于密钥，因此这里必须逐个列举，绝不能用前缀匹配。
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
    'domain_user'
  );
$$;

COMMENT ON FUNCTION public._is_public_system_setting(text) IS
  'system_settings 的公开键白名单（品牌展示 + 用户端域名）。新增键默认不公开；只有确认非密钥且未登录页面必须用到时才可加入。';

GRANT EXECUTE ON FUNCTION public._is_public_system_setting(text) TO anon, authenticated;

ALTER TABLE public.system_settings ENABLE ROW LEVEL SECURITY;

-- 匿名不需要任何写权限
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.system_settings FROM anon;
-- 已登录用户不需要清表/建外键/建触发器权限
REVOKE TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.system_settings FROM authenticated;
GRANT ALL ON TABLE public.system_settings TO service_role;

DROP POLICY IF EXISTS system_settings_public_read ON public.system_settings;
CREATE POLICY system_settings_public_read
  ON public.system_settings
  FOR SELECT
  TO anon, authenticated
  USING (public._is_public_system_setting(key));

DROP POLICY IF EXISTS system_settings_admin_read ON public.system_settings;
CREATE POLICY system_settings_admin_read
  ON public.system_settings
  FOR SELECT
  TO authenticated
  USING (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS system_settings_admin_insert ON public.system_settings;
CREATE POLICY system_settings_admin_insert
  ON public.system_settings
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS system_settings_admin_update ON public.system_settings;
CREATE POLICY system_settings_admin_update
  ON public.system_settings
  FOR UPDATE
  TO authenticated
  USING (public.is_admin(auth.uid()))
  WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS system_settings_admin_delete ON public.system_settings;
CREATE POLICY system_settings_admin_delete
  ON public.system_settings
  FOR DELETE
  TO authenticated
  USING (public.is_admin(auth.uid()));

COMMENT ON TABLE public.system_settings IS
  '全局配置。含大量第三方密钥，因此已启用行级安全：匿名与普通已登录用户只能读 _is_public_system_setting() 白名单内的键，其余读写仅管理员；Edge Function 一律用 service_role 访问。';