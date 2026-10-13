-- 商户内容中心：三张表 + 索引
-- 归属列统一 root_manager_id（企业根管理师），与既有企业级业务表口径一致。

-- 1. 企业板块设置（一企业一行，只存客户侧显示名称）
CREATE TABLE IF NOT EXISTS public.manager_content_spaces (
  root_manager_id uuid PRIMARY KEY
    REFERENCES public.managers(id) ON DELETE CASCADE,
  display_name text
    CHECK (
      display_name IS NULL
      OR char_length(btrim(display_name)) BETWEEN 1 AND 30
    ),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.manager_content_spaces IS
  '商户内容板块设置：客户侧看到的板块名称（耀美学堂 / 关于凯彤），空值展示为「健康学堂」';

-- 2. 内容父表
CREATE TABLE IF NOT EXISTS public.manager_content_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL
    REFERENCES public.managers(id) ON DELETE CASCADE,

  -- 内容本体
  content_type text NOT NULL
    CHECK (content_type IN ('article', 'album')),
  title text NOT NULL DEFAULT ''
    CHECK (char_length(title) <= 200),
  cover_url text,
  cover_storage_key text,
  article_doc jsonb
    CHECK (article_doc IS NULL OR jsonb_typeof(article_doc) = 'object'),

  -- 商户上架意图
  is_published boolean NOT NULL DEFAULT false,
  sort_weight integer NOT NULL DEFAULT 0,

  -- 自动检测（机检）状态与结论
  moderation_status text NOT NULL DEFAULT 'pending'
    CHECK (moderation_status IN (
      'pending', 'passed', 'flagged', 'manual_review', 'blocked'
    )),
  moderation_labels jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(moderation_labels) = 'array'),
  moderation_summary text,
  moderation_checked_images integer NOT NULL DEFAULT 0
    CHECK (moderation_checked_images >= 0),
  moderation_total_images integer NOT NULL DEFAULT 0
    CHECK (moderation_total_images >= 0),
  moderation_error text,
  moderation_attempts integer NOT NULL DEFAULT 0
    CHECK (moderation_attempts >= 0),
  moderated_at timestamptz,

  -- 人工痕迹：被平台下架过一次就永久为 true，机检通过也只能进 manual_review
  requires_manual_review boolean NOT NULL DEFAULT false,
  takedown_note text,
  taken_down_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  taken_down_at timestamptz,

  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  -- 画册内容不存正文文档
  CONSTRAINT manager_content_album_no_article_doc_check
    CHECK (content_type = 'article' OR article_doc IS NULL),
  -- 供子表复合外键引用，锁死子行与父行同企业
  CONSTRAINT manager_content_id_root_unique
    UNIQUE (id, root_manager_id)
);

COMMENT ON COLUMN public.manager_content_items.requires_manual_review IS
  '被平台人工下架过即永久 true；此后机检通过只能到 manual_review，必须人工放行';
COMMENT ON COLUMN public.manager_content_items.moderation_checked_images IS
  '本次机检实际看过的图片张数，与 moderation_total_images 一起对外披露覆盖范围';

-- 3. 画册页
CREATE TABLE IF NOT EXISTS public.manager_content_album_pages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  content_id uuid NOT NULL,
  root_manager_id uuid NOT NULL
    REFERENCES public.managers(id) ON DELETE CASCADE,

  sort_order integer NOT NULL
    CHECK (sort_order >= 0 AND sort_order < 100),
  image_url text NOT NULL
    CHECK (char_length(btrim(image_url)) > 0),
  image_storage_key text NOT NULL
    CHECK (char_length(btrim(image_storage_key)) > 0),
  alt_text text
    CHECK (alt_text IS NULL OR char_length(alt_text) <= 200),

  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT manager_content_album_pages_parent_fkey
    FOREIGN KEY (content_id, root_manager_id)
    REFERENCES public.manager_content_items(id, root_manager_id)
    ON DELETE CASCADE,

  CONSTRAINT manager_content_album_pages_sort_unique
    UNIQUE (content_id, sort_order) DEFERRABLE INITIALLY DEFERRED
);

-- 4. 索引：RLS 用到的 root_manager_id 一律作为首列
CREATE INDEX IF NOT EXISTS manager_content_items_owner_list_idx
  ON public.manager_content_items
  (root_manager_id, sort_weight DESC, updated_at DESC, id);

CREATE INDEX IF NOT EXISTS manager_content_items_owner_status_idx
  ON public.manager_content_items
  (root_manager_id, moderation_status, updated_at DESC, id);

CREATE INDEX IF NOT EXISTS manager_content_items_monitor_idx
  ON public.manager_content_items
  (moderation_status, moderated_at DESC NULLS LAST, id);

CREATE INDEX IF NOT EXISTS manager_content_items_public_idx
  ON public.manager_content_items
  (root_manager_id, sort_weight DESC, created_at DESC, id)
  WHERE is_published = true AND moderation_status = 'passed';

CREATE INDEX IF NOT EXISTS manager_content_album_pages_root_idx
  ON public.manager_content_album_pages
  (root_manager_id, content_id);

CREATE INDEX IF NOT EXISTS manager_content_album_pages_content_sort_idx
  ON public.manager_content_album_pages
  (content_id, sort_order);