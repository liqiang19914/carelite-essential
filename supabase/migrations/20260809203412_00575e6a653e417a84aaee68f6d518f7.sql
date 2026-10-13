ALTER TABLE public.body_compositions
  ADD COLUMN IF NOT EXISTS muscle_percent numeric,
  ADD COLUMN IF NOT EXISTS muscle_storage_score numeric,
  ADD COLUMN IF NOT EXISTS provider_meta jsonb;

ALTER TABLE public.body_compositions
  ADD CONSTRAINT body_compositions_muscle_percent_check
  CHECK (muscle_percent IS NULL OR (muscle_percent >= 0 AND muscle_percent <= 100));

ALTER TABLE public.body_compositions
  ADD CONSTRAINT body_compositions_muscle_storage_score_check
  CHECK (muscle_storage_score IS NULL OR (muscle_storage_score >= 0 AND muscle_storage_score <= 100));

CREATE INDEX IF NOT EXISTS body_compositions_measured_at
  ON public.body_compositions USING btree (measured_at DESC);