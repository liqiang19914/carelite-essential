UPDATE public.acquisition_integration_settings
SET wecom_callback_proxy_url = 'https://qybd.caplinkai.com/hms/acquisition-callback',
    wecom_proxy_status = 'untested',
    wecom_proxy_reason = '已预设 qybd.caplinkai.com，请完成宝塔配置后测试',
    wecom_proxy_checked_at = NULL,
    updated_at = now()
WHERE singleton = true;
