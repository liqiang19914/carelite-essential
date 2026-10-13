-- 达人口碑升级为图文/视频笔记：扩列 + 阅读量 + 置顶
ALTER TABLE public.reputation_posts
  ADD COLUMN IF NOT EXISTS post_type text NOT NULL DEFAULT 'image',
  ADD COLUMN IF NOT EXISTS cover_layout text NOT NULL DEFAULT 'grid',
  ADD COLUMN IF NOT EXISTS video_url text,
  ADD COLUMN IF NOT EXISTS video_storage_key text,
  ADD COLUMN IF NOT EXISTS video_cover_url text,
  ADD COLUMN IF NOT EXISTS video_duration_seconds integer,
  ADD COLUMN IF NOT EXISTS view_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS base_view_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS is_pinned boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS pinned_rank integer NOT NULL DEFAULT 0;

DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'reputation_posts_post_type_chk'
  ) THEN
    ALTER TABLE public.reputation_posts
      ADD CONSTRAINT reputation_posts_post_type_chk
      CHECK (post_type IN ('image', 'video'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'reputation_posts_cover_layout_chk'
  ) THEN
    ALTER TABLE public.reputation_posts
      ADD CONSTRAINT reputation_posts_cover_layout_chk
      CHECK (cover_layout IN ('single', 'triple', 'grid'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'reputation_posts_view_count_chk'
  ) THEN
    ALTER TABLE public.reputation_posts
      ADD CONSTRAINT reputation_posts_view_count_chk
      CHECK (view_count >= 0 AND base_view_count >= 0);
  END IF;
END
$do$;

-- 公开列表排序：品牌 + 审核态 + 置顶 → 置顶次序 → 发布时间
CREATE INDEX IF NOT EXISTS idx_reputation_posts_public_order
  ON public.reputation_posts (
    root_manager_id, moderation_status, is_pinned DESC, pinned_rank DESC, created_at DESC
  );

COMMENT ON COLUMN public.reputation_posts.base_view_count IS '商户设定的初始阅读量；展示阅读量 = view_count + base_view_count';
COMMENT ON COLUMN public.reputation_posts.view_count IS '真实阅读量，详情页每次打开累加 1';