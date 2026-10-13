-- 语音服务配置（ASR 语音识别 + TTS 语音合成）
INSERT INTO system_settings (key, value, description) VALUES
  ('voice_asr_provider', 'default', '语音识别服务商：default（Whisper）/ aliyun'),
  ('voice_asr_aliyun_appkey', '', '阿里云实时语音识别 AppKey'),
  ('voice_asr_aliyun_token', '', '阿里云实时语音识别 Token'),
  ('voice_tts_provider', 'browser', 'TTS服务商：browser（浏览器原生）/ aliyun'),
  ('voice_tts_aliyun_appkey', '', '阿里云语音合成 AppKey'),
  ('voice_tts_aliyun_token', '', '阿里云语音合成 Token'),
  ('voice_tts_voice_name', 'zhichu', 'TTS音色名称，如阿里云：zhichu / zhiyuan / zhixiaoxia')
ON CONFLICT (key) DO NOTHING;