UPDATE system_settings
SET value = 'https://api2026.caplinkai.com',
    updated_at = now()
WHERE key = 'wechat_api_proxy_url';