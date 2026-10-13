
-- 1. 创建短信验证码表
CREATE TABLE IF NOT EXISTS sms_verifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone varchar(20) NOT NULL,
  code varchar(6) NOT NULL,
  expires_at timestamptz NOT NULL,
  attempts int DEFAULT 0,
  used boolean DEFAULT false,
  ip_address varchar(45) DEFAULT '',
  created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_sms_verifications_phone ON sms_verifications(phone, created_at DESC);
CREATE INDEX idx_sms_verifications_expires ON sms_verifications(expires_at);

-- 2. profiles 表增加微信相关字段
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS wechat_openid varchar(64) DEFAULT '';
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS wechat_nickname varchar(100) DEFAULT '';
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS wechat_avatar varchar(500) DEFAULT '';

CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_wechat_openid ON profiles(wechat_openid) WHERE wechat_openid != '';

-- 3. system_settings 插入所有新配置键
INSERT INTO system_settings (key, value, description) VALUES
  -- 域名配置
  ('domain_user', '', '用户端自定义域名，如 user.example.com'),
  ('domain_manager', '', '管理端自定义域名，如 manager.example.com'),
  ('domain_admin', '', '后台端自定义域名，如 admin.example.com'),
  -- 短信服务
  ('sms_enabled', 'false', '是否启用自定义短信服务（阿里云）'),
  ('sms_access_key_id', '', '阿里云 AccessKey ID'),
  ('sms_access_key_secret', '', '阿里云 AccessKey Secret'),
  ('sms_sign_name', '', '短信签名，如 凯同健康'),
  ('sms_template_code', '', '验证码短信模板编号'),
  ('sms_code_expiry', '5', '验证码有效期（分钟）'),
  -- 微信公众号
  ('wechat_enabled', 'false', '是否启用微信公众号登录'),
  ('wechat_app_id', '', '微信公众号 AppID'),
  ('wechat_app_secret', '', '微信公众号 AppSecret'),
  -- 微信支付
  ('wxpay_enabled', 'false', '是否启用微信支付'),
  ('wxpay_mch_id', '', '微信支付商户号'),
  ('wxpay_api_key', '', '微信支付 API 密钥'),
  ('wxpay_api_v3_key', '', '微信支付 API v3 密钥'),
  ('wxpay_cert_serial_no', '', '微信支付商户证书序列号'),
  -- 支付宝
  ('alipay_enabled', 'false', '是否启用支付宝支付'),
  ('alipay_app_id', '', '支付宝应用 AppID'),
  ('alipay_private_key', '', '支付宝应用私钥'),
  ('alipay_public_key', '', '支付宝公钥')
ON CONFLICT (key) DO NOTHING;
