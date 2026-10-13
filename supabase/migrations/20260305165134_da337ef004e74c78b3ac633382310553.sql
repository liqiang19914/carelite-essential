ALTER TABLE client_relations 
ADD COLUMN IF NOT EXISTS health_portrait TEXT DEFAULT '' NOT NULL,
ADD COLUMN IF NOT EXISTS health_portrait_updated_at TIMESTAMPTZ;