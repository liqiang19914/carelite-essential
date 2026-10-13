ALTER TABLE public.acquisition_integration_settings
  ADD COLUMN IF NOT EXISTS wecom_callback_proxy_url text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS wecom_proxy_status text NOT NULL DEFAULT 'untested'
    CHECK (wecom_proxy_status IN ('untested', 'passed', 'failed')),
  ADD COLUMN IF NOT EXISTS wecom_proxy_reason text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS wecom_proxy_checked_at timestamptz;
