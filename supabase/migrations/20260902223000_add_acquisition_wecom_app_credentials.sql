ALTER TABLE public.acquisition_integration_settings
  ADD COLUMN IF NOT EXISTS wecom_agent_id integer,
  ADD COLUMN IF NOT EXISTS wecom_app_secret text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS wecom_acquisition_link_id text NOT NULL DEFAULT '';
