
-- 系统设置表
CREATE TABLE IF NOT EXISTS system_settings (
  key VARCHAR(100) PRIMARY KEY,
  value TEXT NOT NULL DEFAULT '',
  description VARCHAR(500) DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE system_settings IS '系统设置表，存储AI模型配置等全局设置';

-- 插入默认模型设置
INSERT INTO system_settings (key, value, description) VALUES
  ('ai_text_model', 'deepseek-chat', 'AI文本对话模型'),
  ('ai_vision_model', 'qwen3-vl-plus', 'AI视觉识别模型'),
  ('ai_temperature', '0.7', 'AI模型温度参数'),
  ('ai_max_tokens', '2048', 'AI最大输出长度')
ON CONFLICT (key) DO NOTHING;
