INSERT INTO public.system_settings (key, value, description)
VALUES (
  'health365_access_enforcement_enabled',
  'false',
  '365健康管理卡功能总开关（预留位）：当前仅作为配置项存在，尚未接入任何前端/后端拦截逻辑'
)
ON CONFLICT (key) DO NOTHING;