ALTER TABLE public.acquisition_integration_settings
  ADD COLUMN IF NOT EXISTS wecom_contact_secret text NOT NULL DEFAULT '';

COMMENT ON COLUMN public.acquisition_integration_settings.wecom_contact_secret IS
  '企业微信客户联系 Secret，仅供服务端换取客户联系 access_token；禁止返回前端明文。';
