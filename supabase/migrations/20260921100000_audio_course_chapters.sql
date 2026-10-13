-- 语音课程：章节支持 audio 类型
-- 两张章节表（enterprise / manager 各一份）

-- 1. media_type 区分 video / audio，默认 video 兼容历史数据
ALTER TABLE public.enterprise_course_chapters
  ADD COLUMN IF NOT EXISTS media_type text NOT NULL DEFAULT 'video',
  ADD COLUMN IF NOT EXISTS audio_url text,
  ADD COLUMN IF NOT EXISTS audio_storage_key text,
  ADD COLUMN IF NOT EXISTS audio_source text NOT NULL DEFAULT 'oss';

ALTER TABLE public.manager_course_chapters
  ADD COLUMN IF NOT EXISTS media_type text NOT NULL DEFAULT 'video',
  ADD COLUMN IF NOT EXISTS audio_url text,
  ADD COLUMN IF NOT EXISTS audio_storage_key text,
  ADD COLUMN IF NOT EXISTS audio_source text NOT NULL DEFAULT 'oss';

-- 校验 media_type 合法值
DO $$ BEGIN
  ALTER TABLE public.enterprise_course_chapters
    ADD CONSTRAINT enterprise_course_chapters_media_type_check
    CHECK (media_type IN ('video', 'audio'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.manager_course_chapters
    ADD CONSTRAINT manager_course_chapters_media_type_check
    CHECK (media_type IN ('video', 'audio'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 媒体一致约束：audio 类型必须有 audio_url，video 类型必须有 video_url
-- （NOT VALID 先不校验历史数据，新数据靠应用层保证）
DO $$ BEGIN
  ALTER TABLE public.enterprise_course_chapters
    ADD CONSTRAINT enterprise_chapters_media_consistency
    CHECK ((media_type = 'video' AND video_url IS NOT NULL) OR (media_type = 'audio' AND audio_url IS NOT NULL))
    NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.manager_course_chapters
    ADD CONSTRAINT manager_chapters_media_consistency
    CHECK ((media_type = 'video' AND video_url IS NOT NULL) OR (media_type = 'audio' AND audio_url IS NOT NULL))
    NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
