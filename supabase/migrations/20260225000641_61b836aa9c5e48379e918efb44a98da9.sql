
-- 添加 wechat_unionid 字段用于跨端统一用户身份
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS wechat_unionid varchar(64) DEFAULT '';

-- 为 unionid 创建唯一索引（排空值）
CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_wechat_unionid ON profiles(wechat_unionid) WHERE wechat_unionid != '';

-- 添加 phone_bind_required 字段标记首次微信登录需绑定手机
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS phone_bindable boolean DEFAULT false;

-- 插入微信登录相关系统设置（如不存在）
INSERT INTO system_settings (key, value, description, created_at, updated_at) VALUES
  ('wechat_login_mode', 'disabled', '微信登录模式：disabled=关闭, native=原生微信, relay=OAuth中转', now(), now()),
  -- 原生模式配置
  ('wechat_native_open_appid', '', '微信开放平台 AppID（PC扫码登录）', now(), now()),
  ('wechat_native_open_secret', '', '微信开放平台 AppSecret', now(), now()),
  ('wechat_native_mp_appid', '', '微信公众号 AppID（手机授权登录）', now(), now()),
  ('wechat_native_mp_secret', '', '微信公众号 AppSecret', now(), now()),
  ('wechat_native_callback_domain', '', '统一回调域名', now(), now()),
  -- 中转模式配置
  ('wechat_relay_service_url', 'https://wx.caplinkai.com/oauth-authorize', 'OAuth中转服务地址', now(), now()),
  ('wechat_relay_app_id', '', '中转服务应用 ID', now(), now()),
  ('wechat_relay_app_secret', '', '中转服务应用密钥', now(), now()),
  ('wechat_relay_callback_url', '', '中转回调地址', now(), now()),
  ('wechat_relay_pc_mode', 'open_platform', 'PC端登录方式：open_platform=开放平台扫码, mp_qrcode=公众号扫码关注', now(), now())
ON CONFLICT (key) DO NOTHING;
