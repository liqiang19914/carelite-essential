-- ====================================================================
-- 1.A.11：后台商品写入通道 RPC 化（admin write path 硬化）
-- 背景：后台 /admin/shop 走 RLS INSERT 在生产环境间歇性 403，runtime 状态难
-- 定位。统一改走 SECURITY DEFINER RPC，函数内强制 is_admin 校验 + 字段白
-- 名单 + 平台 status 收口（draft/active/archived），绕开 WITH CHECK 同时保
-- 留既有 RLS 作为 defense in depth。
-- ====================================================================

-- ============ A. admin_create_product ============
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
  p_sort_weight     INTEGER DEFAULT 0
) RETURNS products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   UUID := auth.uid();
  v_title TEXT;
  v_row   products;
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

  -- 平台商品 status 仅允许 draft/active/archived
  IF p_status NOT IN ('draft', 'active', 'archived') THEN
    RAISE EXCEPTION 'invalid platform status: %', p_status;
  END IF;

  INSERT INTO products (
    source_type,
    owner_manager_id,
    title,
    subtitle,
    description,
    cover_image_url,
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
  TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT[], TEXT, BOOLEAN, INTEGER
) TO authenticated;

COMMENT ON FUNCTION public.admin_create_product(
  TEXT, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT[], TEXT, BOOLEAN, INTEGER
) IS '后台创建平台严选商品 RPC：admin 权限校验 + source_type=platform 强制 + 默认 SKU 由触发器创建';

-- ============ B. admin_update_product ============
CREATE OR REPLACE FUNCTION public.admin_update_product(
  p_id    UUID,
  p_patch JSONB
) RETURNS products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid    UUID := auth.uid();
  v_row    products;
  v_source TEXT;
  v_title  TEXT;
  v_status TEXT;
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

  UPDATE products SET
    title           = CASE WHEN p_patch ? 'title'           THEN btrim(p_patch->>'title')                    ELSE title END,
    subtitle        = CASE WHEN p_patch ? 'subtitle'        THEN COALESCE(p_patch->>'subtitle', '')           ELSE subtitle END,
    description     = CASE WHEN p_patch ? 'description'     THEN COALESCE(p_patch->>'description', '')        ELSE description END,
    cover_image_url = CASE WHEN p_patch ? 'cover_image_url' THEN COALESCE(p_patch->>'cover_image_url', '')    ELSE cover_image_url END,
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

COMMENT ON FUNCTION public.admin_update_product(UUID, JSONB) IS '后台更新平台严选商品 RPC：admin 权限校验 + 字段白名单 + status 收口（draft/active/archived）';

-- ============ C. admin_update_default_product_sku ============
CREATE OR REPLACE FUNCTION public.admin_update_default_product_sku(
  p_product_id           UUID,
  p_price_cents          INTEGER,
  p_original_price_cents INTEGER,
  p_stock                INTEGER
) RETURNS product_skus
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid    UUID := auth.uid();
  v_source TEXT;
  v_row    product_skus;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden: not authenticated';
  END IF;

  IF NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION 'forbidden: admin role required';
  END IF;

  SELECT source_type INTO v_source FROM products WHERE id = p_product_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'product not found';
  END IF;
  IF v_source <> 'platform' THEN
    RAISE EXCEPTION 'admin_update_default_product_sku only supports platform products';
  END IF;

  IF p_price_cents IS NULL OR p_price_cents < 0 THEN
    RAISE EXCEPTION 'price_cents must be >= 0';
  END IF;
  IF p_stock IS NULL OR p_stock < 0 THEN
    RAISE EXCEPTION 'stock must be >= 0';
  END IF;
  IF p_original_price_cents IS NOT NULL THEN
    IF p_original_price_cents < 0 THEN
      RAISE EXCEPTION 'original_price_cents must be >= 0';
    END IF;
    IF p_original_price_cents < p_price_cents THEN
      RAISE EXCEPTION 'original_price_cents must be >= price_cents';
    END IF;
  END IF;

  UPDATE product_skus SET
    price_cents          = p_price_cents,
    original_price_cents = p_original_price_cents,
    stock                = p_stock
  WHERE product_id = p_product_id
    AND is_default = true
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'default sku not found for product';
  END IF;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_update_default_product_sku(UUID, INTEGER, INTEGER, INTEGER) TO authenticated;

COMMENT ON FUNCTION public.admin_update_default_product_sku(UUID, INTEGER, INTEGER, INTEGER) IS '后台更新平台严选商品默认 SKU 价格/库存 RPC：admin 权限校验 + 非负 + original>=price';