-- =====================================================================
-- 1.B.2.A 商城建档拍照升级 第一阶段
-- 内容:
-- A. products 加 cover_images JSONB + 双向 sync trigger + 旧数据 backfill
-- B. product_image_generations 加 selected_urls / target_type / style_variants
-- C. product_image_gens_lock_update trigger 放行 selected_urls / target_type / style_variants
-- D. admin_create_product 加 p_cover_images 参数
-- E. admin_update_product 白名单加 cover_images
-- F. 索引扩展
-- =====================================================================

-- ============ A. products 新字段 + sync trigger + backfill ============

ALTER TABLE products
  ADD COLUMN IF NOT EXISTS cover_images JSONB NOT NULL DEFAULT '[]'::jsonb;

COMMENT ON COLUMN products.cover_images IS '封面轮播图 URL 数组(1-4 张),cover_images[0] 自动镜像到 cover_image_url 用作首图';

-- backfill: 旧商品 cover_image_url 同步到 cover_images
UPDATE products
SET cover_images = jsonb_build_array(cover_image_url)
WHERE cover_image_url <> ''
  AND (cover_images IS NULL OR jsonb_array_length(cover_images) = 0);

-- cover_images <-> cover_image_url 双向同步 trigger
CREATE OR REPLACE FUNCTION public.products_sync_cover_mirror()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- 优先路径:cover_images 数组有值 -> cover_image_url 取首张
  IF TG_OP = 'INSERT' THEN
    IF jsonb_typeof(NEW.cover_images) = 'array' AND jsonb_array_length(NEW.cover_images) > 0 THEN
      NEW.cover_image_url := COALESCE(NEW.cover_images->>0, '');
    ELSIF COALESCE(NEW.cover_image_url, '') <> '' THEN
      -- 老路径:只填了 cover_image_url -> 反向同步到 cover_images
      NEW.cover_images := jsonb_build_array(NEW.cover_image_url);
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE 路径
  IF NEW.cover_images IS DISTINCT FROM OLD.cover_images THEN
    -- cover_images 变化 -> cover_image_url 取首张(或清空)
    IF jsonb_typeof(NEW.cover_images) = 'array' AND jsonb_array_length(NEW.cover_images) > 0 THEN
      NEW.cover_image_url := COALESCE(NEW.cover_images->>0, '');
    ELSE
      NEW.cover_image_url := '';
    END IF;
  ELSIF NEW.cover_image_url IS DISTINCT FROM OLD.cover_image_url THEN
    -- 只改了 cover_image_url(老路径调用方),把它同步到 cover_images[0]
    IF COALESCE(NEW.cover_image_url, '') <> '' THEN
      NEW.cover_images := jsonb_build_array(NEW.cover_image_url);
    ELSE
      NEW.cover_images := '[]'::jsonb;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS products_sync_cover_mirror_trigger ON products;

CREATE TRIGGER products_sync_cover_mirror_trigger
BEFORE INSERT OR UPDATE OF cover_images, cover_image_url
ON products
FOR EACH ROW
EXECUTE FUNCTION public.products_sync_cover_mirror();

COMMENT ON FUNCTION public.products_sync_cover_mirror() IS '保证 cover_image_url === cover_images[0],兼容老调用路径与新轮播写入';

-- ============ B. product_image_generations 新字段 ============

ALTER TABLE product_image_generations
  ADD COLUMN IF NOT EXISTS selected_urls JSONB NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE product_image_generations
  ADD COLUMN IF NOT EXISTS target_type TEXT NOT NULL DEFAULT 'cover';

-- 先删旧 CHECK(如果存在),再加新的(允许多次执行)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'product_image_generations_target_type_check'
  ) THEN
    ALTER TABLE product_image_generations
      DROP CONSTRAINT product_image_generations_target_type_check;
  END IF;
END $$;

ALTER TABLE product_image_generations
  ADD CONSTRAINT product_image_generations_target_type_check
  CHECK (target_type IN ('cover','gallery','detail'));

ALTER TABLE product_image_generations
  ADD COLUMN IF NOT EXISTS style_variants JSONB NOT NULL DEFAULT '[]'::jsonb;

COMMENT ON COLUMN product_image_generations.selected_urls IS '多选场景的最终入选 URL 数组(顺序即轮播顺序);单选场景与 selected_url 同步';
COMMENT ON COLUMN product_image_generations.target_type IS '生成目标:cover=封面 / gallery=图集单张 / detail=电商详情页';
COMMENT ON COLUMN product_image_generations.style_variants IS '每路 fan-out 的风格元数据,格式 [{key,label,prompt}]';

-- ============ C. product_image_gens_lock_update 放行 selected_urls 等 ============

CREATE OR REPLACE FUNCTION public.product_image_gens_lock_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    -- service_role 绕过(EF 写入)
    RETURN NEW;
  END IF;

  -- cascade SET NULL 路径放行(20260524153407 加的防御)
  IF NEW.product_id IS NULL AND OLD.product_id IS NOT NULL
     AND NEW.id = OLD.id
     AND NEW.user_id = OLD.user_id
     AND NEW.source_image_url = OLD.source_image_url
     AND NEW.prompt = OLD.prompt
     AND NEW.preset_key = OLD.preset_key
     AND NEW.candidate_urls IS NOT DISTINCT FROM OLD.candidate_urls
     AND NEW.selected_url = OLD.selected_url
     AND NEW.selected_urls IS NOT DISTINCT FROM OLD.selected_urls
     AND NEW.count = OLD.count
     AND NEW.status = OLD.status
     AND NEW.model_used = OLD.model_used
     AND NEW.error_message = OLD.error_message
     AND NEW.created_at = OLD.created_at
     AND NEW.target_type = OLD.target_type
     AND NEW.style_variants IS NOT DISTINCT FROM OLD.style_variants
     AND NEW.completed_at IS NOT DISTINCT FROM OLD.completed_at THEN
    RETURN NEW;
  END IF;

  -- 客户端只允许改 selected_url 和 selected_urls
  IF NEW.id IS DISTINCT FROM OLD.id
    OR NEW.product_id IS DISTINCT FROM OLD.product_id
    OR NEW.user_id IS DISTINCT FROM OLD.user_id
    OR NEW.source_image_url IS DISTINCT FROM OLD.source_image_url
    OR NEW.prompt IS DISTINCT FROM OLD.prompt
    OR NEW.preset_key IS DISTINCT FROM OLD.preset_key
    OR NEW.candidate_urls IS DISTINCT FROM OLD.candidate_urls
    OR NEW.count IS DISTINCT FROM OLD.count
    OR NEW.status IS DISTINCT FROM OLD.status
    OR NEW.model_used IS DISTINCT FROM OLD.model_used
    OR NEW.error_message IS DISTINCT FROM OLD.error_message
    OR NEW.created_at IS DISTINCT FROM OLD.created_at
    OR NEW.target_type IS DISTINCT FROM OLD.target_type
    OR NEW.style_variants IS DISTINCT FROM OLD.style_variants
    OR NEW.completed_at IS DISTINCT FROM OLD.completed_at THEN
    RAISE EXCEPTION 'product_image_generations: only selected_url and selected_urls are mutable by client';
  END IF;

  RETURN NEW;
END;
$$;

-- ============ D. admin_create_product 加 p_cover_images 参数(需要 DROP+CREATE) ============

DROP FUNCTION IF EXISTS public.admin_create_product(
  TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT[], TEXT, BOOLEAN, INTEGER
);

CREATE OR REPLACE FUNCTION public.admin_create_product(
  p_title           TEXT,
  p_subtitle        TEXT DEFAULT '',
  p_description     TEXT DEFAULT '',
  p_cover_image_url TEXT DEFAULT '',
  p_gallery_images  JSONB DEFAULT '[]'::jsonb,
  p_category        TEXT DEFAULT 'general',
  p_tags            TEXT[] DEFAULT '{}'::text[],
  p_status          TEXT DEFAULT 'draft',
  p_is_featured     BOOLEAN DEFAULT false,
  p_sort_weight     INTEGER DEFAULT 0,
  p_cover_images    JSONB DEFAULT NULL
) RETURNS products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid           UUID := auth.uid();
  v_title         TEXT;
  v_cover_images  JSONB;
  v_row           products;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden: not authenticated';
  END IF;

  IF NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION 'forbidden: admin role required';
  END IF;

  v_title := btrim(COALESCE(p_title, ''));
  IF v_title = '' THEN
    RAISE EXCEPTION 'product title required';
  END IF;
  IF char_length(v_title) > 200 THEN
    RAISE EXCEPTION 'product title too long (max 200)';
  END IF;

  IF p_status NOT IN ('draft', 'active', 'archived') THEN
    RAISE EXCEPTION 'invalid platform status: %', p_status;
  END IF;

  -- 解析 cover_images:优先 p_cover_images 数组,其次回退到 p_cover_image_url 单图
  IF p_cover_images IS NOT NULL AND jsonb_typeof(p_cover_images) = 'array' THEN
    IF jsonb_array_length(p_cover_images) > 4 THEN
      RAISE EXCEPTION 'cover_images can contain at most 4 entries';
    END IF;
    v_cover_images := p_cover_images;
  ELSIF COALESCE(p_cover_image_url, '') <> '' THEN
    v_cover_images := jsonb_build_array(p_cover_image_url);
  ELSE
    v_cover_images := '[]'::jsonb;
  END IF;

  INSERT INTO products (
    source_type,
    owner_manager_id,
    title,
    subtitle,
    description,
    cover_image_url,
    cover_images,
    gallery_images,
    category,
    tags,
    status,
    is_featured,
    sort_weight,
    created_by
  ) VALUES (
    'platform',
    NULL,
    v_title,
    COALESCE(p_subtitle, ''),
    COALESCE(p_description, ''),
    COALESCE(p_cover_image_url, ''),
    v_cover_images,
    COALESCE(p_gallery_images, '[]'::jsonb),
    COALESCE(NULLIF(btrim(p_category), ''), 'general'),
    COALESCE(p_tags, '{}'::text[]),
    p_status,
    COALESCE(p_is_featured, false),
    COALESCE(p_sort_weight, 0),
    v_uid
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_create_product(
  TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT[], TEXT, BOOLEAN, INTEGER, JSONB
) TO authenticated;

COMMENT ON FUNCTION public.admin_create_product(
  TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT[], TEXT, BOOLEAN, INTEGER, JSONB
) IS '后台创建平台严选商品 RPC(1.B.2.A):admin 权限校验 + source_type=platform + 默认 SKU 自动创建 + cover_images 多张轮播支持';

-- ============ E. admin_update_product 白名单加 cover_images ============

CREATE OR REPLACE FUNCTION public.admin_update_product(
  p_id    UUID,
  p_patch JSONB
) RETURNS products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid           UUID := auth.uid();
  v_row           products;
  v_source        TEXT;
  v_title         TEXT;
  v_status        TEXT;
  v_cover_images  JSONB;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden: not authenticated';
  END IF;

  IF NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION 'forbidden: admin role required';
  END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'patch must be a json object';
  END IF;

  SELECT source_type INTO v_source FROM products WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'product not found';
  END IF;
  IF v_source <> 'platform' THEN
    RAISE EXCEPTION 'admin_update_product only supports platform products';
  END IF;

  IF p_patch ? 'title' THEN
    v_title := btrim(COALESCE(p_patch->>'title', ''));
    IF v_title = '' THEN
      RAISE EXCEPTION 'product title required';
    END IF;
    IF char_length(v_title) > 200 THEN
      RAISE EXCEPTION 'product title too long (max 200)';
    END IF;
  END IF;

  IF p_patch ? 'status' THEN
    v_status := p_patch->>'status';
    IF v_status NOT IN ('draft', 'active', 'archived') THEN
      RAISE EXCEPTION 'invalid platform status: %', v_status;
    END IF;
  END IF;

  IF p_patch ? 'cover_images' THEN
    v_cover_images := p_patch->'cover_images';
    IF jsonb_typeof(v_cover_images) <> 'array' THEN
      RAISE EXCEPTION 'cover_images must be a JSON array';
    END IF;
    IF jsonb_array_length(v_cover_images) > 4 THEN
      RAISE EXCEPTION 'cover_images can contain at most 4 entries';
    END IF;
  END IF;

  UPDATE products SET
    title           = CASE WHEN p_patch ? 'title'           THEN btrim(p_patch->>'title')                    ELSE title END,
    subtitle        = CASE WHEN p_patch ? 'subtitle'        THEN COALESCE(p_patch->>'subtitle', '')           ELSE subtitle END,
    description     = CASE WHEN p_patch ? 'description'     THEN COALESCE(p_patch->>'description', '')        ELSE description END,
    cover_image_url = CASE WHEN p_patch ? 'cover_image_url' THEN COALESCE(p_patch->>'cover_image_url', '')    ELSE cover_image_url END,
    cover_images    = CASE WHEN p_patch ? 'cover_images'    THEN COALESCE(p_patch->'cover_images', '[]'::jsonb) ELSE cover_images END,
    gallery_images  = CASE WHEN p_patch ? 'gallery_images'  THEN COALESCE(p_patch->'gallery_images', '[]'::jsonb) ELSE gallery_images END,
    category        = CASE WHEN p_patch ? 'category'        THEN COALESCE(NULLIF(btrim(p_patch->>'category'), ''), 'general') ELSE category END,
    tags            = CASE WHEN p_patch ? 'tags' THEN COALESCE(
                            ARRAY(SELECT jsonb_array_elements_text(p_patch->'tags')),
                            '{}'::text[]
                          )
                          ELSE tags
                      END,
    status          = CASE WHEN p_patch ? 'status'          THEN p_patch->>'status'                           ELSE status END,
    is_featured     = CASE WHEN p_patch ? 'is_featured'     THEN COALESCE((p_patch->>'is_featured')::boolean, is_featured) ELSE is_featured END,
    sort_weight     = CASE WHEN p_patch ? 'sort_weight'     THEN COALESCE((p_patch->>'sort_weight')::integer, sort_weight) ELSE sort_weight END
  WHERE id = p_id
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product not found';
  END IF;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_update_product(UUID, JSONB) TO authenticated;

COMMENT ON FUNCTION public.admin_update_product(UUID, JSONB) IS '后台更新平台严选商品 RPC(1.B.2.A):admin 权限校验 + 字段白名单(含 cover_images) + status 收口';

-- ============ F. 索引扩展 ============

CREATE INDEX IF NOT EXISTS idx_product_image_gens_target_type
  ON product_image_generations (target_type, created_at DESC);
