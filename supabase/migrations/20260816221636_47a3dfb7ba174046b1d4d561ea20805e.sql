-- ============================================================================
-- 达人口碑 UGC 论坛：5 张表 + 索引 + RLS（全走 SECURITY DEFINER RPC，表不直接授权）
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.reputation_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 30),
  sort_weight int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reputation_categories_root_name_unique UNIQUE (root_manager_id, name)
);

CREATE TABLE IF NOT EXISTS public.reputation_posts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  category_id uuid REFERENCES public.reputation_categories(id) ON DELETE SET NULL,
  author_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 50),
  content text NOT NULL CHECK (char_length(btrim(content)) BETWEEN 1 AND 2000),
  like_count int NOT NULL DEFAULT 0,
  comment_count int NOT NULL DEFAULT 0,
  moderation_status text NOT NULL DEFAULT 'pending'
    CHECK (moderation_status IN ('pending','passed','flagged','manual_review','blocked')),
  review_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reputation_posts_root_status
  ON public.reputation_posts (root_manager_id, moderation_status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reputation_posts_author
  ON public.reputation_posts (author_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reputation_posts_category
  ON public.reputation_posts (category_id);

CREATE TABLE IF NOT EXISTS public.reputation_post_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid NOT NULL REFERENCES public.reputation_posts(id) ON DELETE CASCADE,
  image_url text NOT NULL,
  image_storage_key text,
  sort_order int NOT NULL DEFAULT 0,
  is_before boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_reputation_images_post
  ON public.reputation_post_images (post_id, sort_order);

CREATE TABLE IF NOT EXISTS public.reputation_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid NOT NULL REFERENCES public.reputation_posts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  content text NOT NULL CHECK (char_length(btrim(content)) BETWEEN 1 AND 500),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_reputation_comments_post
  ON public.reputation_comments (post_id, created_at DESC, id);

CREATE TABLE IF NOT EXISTS public.reputation_likes (
  post_id uuid NOT NULL REFERENCES public.reputation_posts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, user_id)
);

-- RLS：全走 RPC，表不直接授权给 anon/authenticated
ALTER TABLE public.reputation_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reputation_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reputation_post_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reputation_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reputation_likes ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.reputation_categories FROM anon, authenticated;
REVOKE ALL ON public.reputation_posts FROM anon, authenticated;
REVOKE ALL ON public.reputation_post_images FROM anon, authenticated;
REVOKE ALL ON public.reputation_comments FROM anon, authenticated;
REVOKE ALL ON public.reputation_likes FROM anon, authenticated;

-- Realtime publication（幂等）：帖子计数变更 + 新评论实时推送
DO $rt$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'reputation_posts'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.reputation_posts;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'reputation_comments'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.reputation_comments;
  END IF;
END $rt$;