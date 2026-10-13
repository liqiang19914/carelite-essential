ALTER TABLE public.client_relations
ADD COLUMN IF NOT EXISTS follow_up_suggestion TEXT DEFAULT '' NOT NULL,
ADD COLUMN IF NOT EXISTS follow_up_suggestion_updated_at TIMESTAMPTZ;