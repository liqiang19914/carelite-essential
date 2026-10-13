CREATE TABLE IF NOT EXISTS public.profile_merge_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL,
  target_id uuid NOT NULL,
  phone text,
  moved jsonb NOT NULL DEFAULT '{}'::jsonb,
  dropped jsonb NOT NULL DEFAULT '{}'::jsonb,
  performed_by uuid,
  performed_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.profile_merge_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY admin_all_profile_merge_log ON public.profile_merge_log
  FOR ALL USING (public.is_admin((SELECT auth.uid())));

CREATE POLICY service_all_profile_merge_log ON public.profile_merge_log
  FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_profile_merge_log_performed_at
  ON public.profile_merge_log (performed_at DESC);