-- feature 457: 内容/课程短码列 + 唯一索引（partial WHERE short_code IS NOT NULL）
-- 幂等：IF NOT EXISTS / DROP CONSTRAINT IF EXISTS 后再 CREATE

ALTER TABLE public.manager_content_items
  ADD COLUMN IF NOT EXISTS short_code character varying(6);

CREATE UNIQUE INDEX IF NOT EXISTS manager_content_items_short_code_uniq
  ON public.manager_content_items (short_code)
  WHERE short_code IS NOT NULL;

ALTER TABLE public.manager_content_items
  DROP CONSTRAINT IF EXISTS manager_content_items_short_code_format_check;
ALTER TABLE public.manager_content_items
  ADD CONSTRAINT manager_content_items_short_code_format_check
  CHECK (short_code IS NULL OR short_code ~ '^[a-z0-9]{6}$');


ALTER TABLE public.enterprise_courses
  ADD COLUMN IF NOT EXISTS short_code character varying(6);

CREATE UNIQUE INDEX IF NOT EXISTS enterprise_courses_short_code_uniq
  ON public.enterprise_courses (short_code)
  WHERE short_code IS NOT NULL;

ALTER TABLE public.enterprise_courses
  DROP CONSTRAINT IF EXISTS enterprise_courses_short_code_format_check;
ALTER TABLE public.enterprise_courses
  ADD CONSTRAINT enterprise_courses_short_code_format_check
  CHECK (short_code IS NULL OR short_code ~ '^[a-z0-9]{6}$');


ALTER TABLE public.manager_courses
  ADD COLUMN IF NOT EXISTS short_code character varying(6);

CREATE UNIQUE INDEX IF NOT EXISTS manager_courses_short_code_uniq
  ON public.manager_courses (short_code)
  WHERE short_code IS NOT NULL;

ALTER TABLE public.manager_courses
  DROP CONSTRAINT IF EXISTS manager_courses_short_code_format_check;
ALTER TABLE public.manager_courses
  ADD CONSTRAINT manager_courses_short_code_format_check
  CHECK (short_code IS NULL OR short_code ~ '^[a-z0-9]{6}$');