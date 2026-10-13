-- Add preview_audio_url to manager_voice_profiles for caching synthesized preview audio
ALTER TABLE manager_voice_profiles
  ADD COLUMN IF NOT EXISTS preview_audio_url text NOT NULL DEFAULT '';

-- Add voice_preference to profiles so users can choose their TTS voice
-- Values: 'manager' = use manager's custom voice (default), 'system' = system default, 'off' = no TTS
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS voice_preference character varying(20) NOT NULL DEFAULT 'manager';

COMMENT ON COLUMN manager_voice_profiles.preview_audio_url IS '缓存的试听音频S3 URL，首次合成后上传保存，后续直接从CDN加载';
COMMENT ON COLUMN profiles.voice_preference IS '用户语音偏好: manager=使用管理师声音(默认), system=系统默认音色, off=关闭语音播报';