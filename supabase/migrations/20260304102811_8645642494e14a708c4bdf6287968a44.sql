INSERT INTO system_settings (key, value, description, created_at, updated_at)
VALUES (
  'wechat_api_proxy_url',
  'https://api2026.caplinkai.com/wechat-api',
  '微信API反向代理地址，用于解决Supabase出口IP动态变化导致的IP白名单问题',
  now(),
  now()
)
ON CONFLICT (key) DO UPDATE SET
  value = EXCLUDED.value,
  description = EXCLUDED.description,
  updated_at = now();