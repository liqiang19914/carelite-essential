CREATE TABLE IF NOT EXISTS public.manager_course_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL
    REFERENCES public.managers(id) ON DELETE CASCADE,
  name text NOT NULL
    CHECK (char_length(btrim(name)) BETWEEN 1 AND 50),
  sort_weight integer NOT NULL DEFAULT 0,
  cover_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT manager_course_categories_root_name_uniq UNIQUE (root_manager_id, name)
);

CREATE INDEX IF NOT EXISTS manager_course_categories_root_idx
  ON public.manager_course_categories (root_manager_id, sort_weight DESC, id);

ALTER TABLE public.manager_courses
  ADD COLUMN IF NOT EXISTS category_id uuid
    REFERENCES public.manager_course_categories(id) ON DELETE SET NULL;

ALTER TABLE public.manager_courses
  ADD COLUMN IF NOT EXISTS study_count integer NOT NULL DEFAULT 0;

ALTER TABLE public.manager_courses
  ADD COLUMN IF NOT EXISTS like_count integer NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS manager_courses_pub_sort_idx
  ON public.manager_courses (manager_id, is_published, review_status, sort_weight DESC, created_at DESC);