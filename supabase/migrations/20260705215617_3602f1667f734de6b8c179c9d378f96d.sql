CREATE TABLE manager_miniapp_code_cache (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  manager_id uuid NOT NULL REFERENCES managers(id) ON DELETE CASCADE,
  credential_source text NOT NULL CHECK (credential_source IN ('manager_oem','platform')),
  app_id text NOT NULL,
  entry_type text NOT NULL,
  page text NOT NULL,
  scene text NOT NULL,
  mime_type text NOT NULL,
  image_base64 text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (app_id, page, scene)
);

CREATE INDEX idx_manager_miniapp_code_cache_manager_id ON manager_miniapp_code_cache(manager_id);

ALTER TABLE manager_miniapp_code_cache ENABLE ROW LEVEL SECURITY;

INSERT INTO system_settings (key, value, description) VALUES
('miniapp_wxacode_enabled', 'false', '是否启用原生小程序码：需在小程序壳重新发布并验证密钥后手动开启')
ON CONFLICT (key) DO NOTHING;
