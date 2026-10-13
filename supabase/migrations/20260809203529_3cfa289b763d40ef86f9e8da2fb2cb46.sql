INSERT INTO public.device_providers (
  provider_key, display_name, integration_type, auth_model, data_domain,
  plugin_provider_appid, plugin_version, required_request_domains, required_privacy_apis,
  entry_page, status, description
) VALUES (
  'picooc_scale',
  '有品体脂秤',
  'mp_plugin',
  'vendor_key',
  'body_composition',
  'wx7ef22d76b1b81c40',
  '2.0.1',
  ARRAY[]::text[],
  ARRAY['BluetoothAPI','LocationAPI']::text[],
  '/pages/weigh-picooc/index',
  'active',
  '有品 PicoocWeigh 小程序插件，mini-c 充电款 / mini 电池款；需接入方 appId+appSecret，按商户配置在 oem_device_grants.provider_config'
)
ON CONFLICT (provider_key) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  integration_type = EXCLUDED.integration_type,
  auth_model = EXCLUDED.auth_model,
  data_domain = EXCLUDED.data_domain,
  plugin_provider_appid = EXCLUDED.plugin_provider_appid,
  plugin_version = EXCLUDED.plugin_version,
  required_privacy_apis = EXCLUDED.required_privacy_apis,
  entry_page = EXCLUDED.entry_page,
  status = EXCLUDED.status,
  description = EXCLUDED.description,
  updated_at = now();