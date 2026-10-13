
-- 管理师声音配置表
CREATE TABLE IF NOT EXISTS manager_voice_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  manager_id uuid NOT NULL UNIQUE REFERENCES profiles(id) ON DELETE CASCADE,
  sample_url text NOT NULL DEFAULT '',
  cosyvoice_voice_id text NOT NULL DEFAULT '',
  cosyvoice_model text NOT NULL DEFAULT 'cosyvoice-v3-plus',
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'cloning', 'ready', 'failed')),
  error_message text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_manager_voice_profiles_manager_id ON manager_voice_profiles(manager_id);
CREATE INDEX IF NOT EXISTS idx_manager_voice_profiles_status ON manager_voice_profiles(status);

COMMENT ON TABLE manager_voice_profiles IS '管理师声音配置表，存储 CosyVoice 声音克隆信息';
COMMENT ON COLUMN manager_voice_profiles.sample_url IS '上传的原始语音样本文件URL';
COMMENT ON COLUMN manager_voice_profiles.cosyvoice_voice_id IS 'CosyVoice API 返回的克隆声音ID，用于 TTS 合成';
COMMENT ON COLUMN manager_voice_profiles.cosyvoice_model IS '使用的 CosyVoice 模型，如 cosyvoice-v3-plus';
COMMENT ON COLUMN manager_voice_profiles.status IS '状态: pending=待克隆, cloning=克隆中, ready=可用, failed=失败';
