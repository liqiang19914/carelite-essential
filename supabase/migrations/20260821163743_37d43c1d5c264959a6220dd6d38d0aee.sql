ALTER TABLE public.managers
  ADD COLUMN IF NOT EXISTS is_system_default boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS system_default_key text,
  ADD COLUMN IF NOT EXISTS is_platform_root boolean NOT NULL DEFAULT false;

CREATE UNIQUE INDEX IF NOT EXISTS managers_system_default_enterprise_key_uniq
  ON public.managers (enterprise_id, system_default_key)
  WHERE is_system_default = true;