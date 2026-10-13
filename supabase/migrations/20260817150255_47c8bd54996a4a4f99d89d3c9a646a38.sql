-- Feature 133 内容管理升级与企业级课程
-- 第一部分：企业级课程表 + 内容统计字段

CREATE TABLE IF NOT EXISTS public.enterprise_course_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  enterprise_id uuid NOT NULL REFERENCES public.enterprises(id) ON DELETE CASCADE,
  name text NOT NULL DEFAULT '',
  sort_weight integer NOT NULL DEFAULT 0,
  cover_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ecc_enterprise_idx ON public.enterprise_course_categories (enterprise_id, sort_weight DESC);

CREATE TABLE IF NOT EXISTS public.enterprise_courses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  enterprise_id uuid NOT NULL REFERENCES public.enterprises(id) ON DELETE CASCADE,
  category_id uuid REFERENCES public.enterprise_course_categories(id) ON DELETE SET NULL,
  title text NOT NULL DEFAULT '',
  cover_image_url text,
  description text,
  duration_minutes integer,
  is_published boolean NOT NULL DEFAULT false,
  sort_weight integer NOT NULL DEFAULT 0,
  study_count integer NOT NULL DEFAULT 0,
  like_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ec_enterprise_idx ON public.enterprise_courses (enterprise_id, is_published, sort_weight DESC);

CREATE TABLE IF NOT EXISTS public.enterprise_course_chapters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  course_id uuid NOT NULL REFERENCES public.enterprise_courses(id) ON DELETE CASCADE,
  sort_order integer NOT NULL DEFAULT 0,
  title text NOT NULL DEFAULT '',
  intro text,
  duration_seconds integer,
  video_url text,
  video_storage_key text,
  video_source text NOT NULL DEFAULT 'upload',
  cover_url text,
  is_free_preview boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ecc_chapter_course_idx ON public.enterprise_course_chapters (course_id, sort_order);

CREATE TABLE IF NOT EXISTS public.enterprise_course_likes (
  course_id uuid NOT NULL REFERENCES public.enterprise_courses(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (course_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.enterprise_course_studies (
  course_id uuid NOT NULL REFERENCES public.enterprise_courses(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (course_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.health_manager_course_links (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  course_id uuid NOT NULL REFERENCES public.enterprise_courses(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (manager_id, course_id)
);

CREATE INDEX IF NOT EXISTS hmcl_course_idx ON public.health_manager_course_links (course_id);

ALTER TABLE public.manager_content_items
  ADD COLUMN IF NOT EXISTS view_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS is_pinned boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS pinned_rank integer NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS mci_pinned_idx ON public.manager_content_items (root_manager_id, is_pinned, pinned_rank DESC);