-- ============================================================
-- 商品富文本描述（Feature 191）
-- products.description_doc 已在 20260819032951 加入，这里把三个商户写入 RPC 透传它：
--   1. manager_create_product: 新增 p_description_doc 参数
--   2. manager_update_product: 白名单 + SET 增加 description_doc
--   3. manager_save_product_with_sku 走 manager_update_product，自动继承
-- description 仍然是纯文本镜像，供 AI 润色 / 搜索 / 老商品回退。
-- ============================================================

-- 1. manager_create_product: 加 p_description_doc
CREATE OR REPLACE FUNCTION public.manager_create_product(
  p_title           text,
  p_subtitle        text    DEFAULT ''::text,
  p_description     text    DEFAULT ''::text,
  p_cover_image_url text    DEFAULT ''::text,
  p_cover_images    jsonb   DEFAULT NULL::jsonb,
  p_gallery_images  jsonb   DEFAULT '[]'::jsonb,
  p_category        text    DEFAULT 'general'::text,
  p_tags            text[]  DEFAULT '{}'::text[],
  p_status          text    DEFAULT 'draft'::text,
  p_sort_weight     integer DEFAULT 0,
  p_sale_mode       text    DEFAULT 'cash'::text,
  p_description_doc jsonb   DEFAULT NULL::jsonb
)
RETURNS products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          UUID := auth.uid();
  v_role         TEXT;
  v_disabled     BOOLEAN;
  v_title        TEXT;
  v_status       TEXT;
  v_cover_images JSONB;
  v_sale_mode    TEXT;
  v_row          products;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden: not authenticated';
  END IF;

  SELECT role::text, COALESCE(is_disabled, false)
    INTO v_role, v_disabled
  FROM profiles WHERE id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'forbidden: profile missing';
  END IF;
  IF v_role IS DISTINCT FROM 'manager' THEN
    RAISE EXCEPTION 'forbidden: manager role required';
  END IF;
  IF v_disabled THEN
    RAISE EXCEPTION 'forbidden: account disabled';
  END IF;

  v_title := btrim(COALESCE(p_title, ''));
  IF v_title = '' THEN
    RAISE EXCEPTION 'product title required';
  END IF;
  IF char_length(v_title) > 200 THEN
    RAISE EXCEPTION 'product title too long (max 200)';
  END IF;

  v_status := COALESCE(NULLIF(btrim(COALESCE(p_status, '')), ''), 'draft');
  IF v_status NOT IN ('draft', 'pending_review') THEN
    RAISE EXCEPTION 'invalid manager status: %', v_status;
  END IF;

  v_sale_mode := COALESCE(NULLIF(btrim(COALESCE(p_sale_mode, '')), ''), 'cash');
  IF v_sale_mode NOT IN ('cash', 'points') THEN
    RAISE EXCEPTION 'invalid sale_mode: %', v_sale_mode;
  END IF;

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
    source_type, owner_manager_id, title, subtitle, description,
    cover_image_url, cover_images, gallery_images, category, tags,
    status, is_featured, sort_weight, created_by, sale_mode,
    description_doc
  ) VALUES (
    'manager', v_uid, v_title,
    COALESCE(p_subtitle, ''), COALESCE(p_description, ''),
    COALESCE(p_cover_image_url, ''), v_cover_images,
    COALESCE(p_gallery_images, '[]'::jsonb),
    COALESCE(NULLIF(btrim(COALESCE(p_category, '')), ''), 'general'),
    COALESCE(p_tags, '{}'::text[]),
    v_status, false, COALESCE(p_sort_weight, 0), v_uid,
    v_sale_mode,
    p_description_doc
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_create_product(
  text, text, text, text, jsonb, jsonb, text, text[], text, integer, text, jsonb
) TO authenticated;

-- 2. manager_update_product: 白名单 + SET 增加 description_doc
CREATE OR REPLACE FUNCTION public.manager_update_product(
  p_id              uuid,
  p_patch           jsonb,
  p_expected_status text[] DEFAULT NULL
)
RETURNS products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid         UUID := auth.uid();
  v_role        TEXT;
  v_disabled    BOOLEAN;
  v_owner       UUID;
  v_source      TEXT;
  v_cur_status  TEXT;
  v_title       TEXT;
  v_status      TEXT;
  v_sale_mode   TEXT;
  v_cover       JSONB;
  v_unknown_key TEXT;
  v_row         products;
  v_allowed     CONSTANT TEXT[] := ARRAY[
    'title', 'subtitle', 'description',
    'cover_image_url', 'cover_images', 'gallery_images',
    'category', 'tags',
    'status', 'sort_weight', 'sale_mode',
    'description_doc'
  ];
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden: not authenticated';
  END IF;

  SELECT role::text, COALESCE(is_disabled, false)
    INTO v_role, v_disabled
  FROM profiles WHERE id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'forbidden: profile missing';
  END IF;
  IF v_role IS DISTINCT FROM 'manager' THEN
    RAISE EXCEPTION 'forbidden: manager role required';
  END IF;
  IF v_disabled THEN
    RAISE EXCEPTION 'forbidden: account disabled';
  END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'patch must be a json object';
  END IF;

  SELECT k INTO v_unknown_key
  FROM jsonb_object_keys(p_patch) AS k
  WHERE k <> ALL(v_allowed)
  LIMIT 1;
  IF v_unknown_key IS NOT NULL THEN
    RAISE EXCEPTION 'unknown patch key: %', v_unknown_key;
  END IF;

  SELECT source_type, owner_manager_id, status
    INTO v_source, v_owner, v_cur_status
  FROM products WHERE id = p_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product not found';
  END IF;
  IF v_source <> 'manager' OR v_owner IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'forbidden: not product owner';
  END IF;

  IF p_expected_status IS NOT NULL
     AND array_length(p_expected_status, 1) > 0
     AND NOT (v_cur_status = ANY(p_expected_status)) THEN
    RAISE EXCEPTION 'product status changed';
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
    v_status := btrim(COALESCE(p_patch->>'status', ''));
    IF v_status NOT IN ('draft', 'pending_review', 'archived') THEN
      RAISE EXCEPTION 'invalid manager status: %', v_status;
    END IF;
    IF v_cur_status = 'active' AND v_status NOT IN ('pending_review', 'archived') THEN
      RAISE EXCEPTION 'active product can only go to review or archived';
    END IF;
  END IF;

  IF p_patch ? 'sale_mode' THEN
    v_sale_mode := btrim(COALESCE(p_patch->>'sale_mode', ''));
    IF v_sale_mode NOT IN ('cash', 'points') THEN
      RAISE EXCEPTION 'invalid sale_mode: %', v_sale_mode;
    END IF;
  END IF;

  IF p_patch ? 'cover_images' THEN
    v_cover := p_patch->'cover_images';
    IF jsonb_typeof(v_cover) <> 'array' THEN
      RAISE EXCEPTION 'cover_images must be a JSON array';
    END IF;
    IF jsonb_array_length(v_cover) > 4 THEN
      RAISE EXCEPTION 'cover_images can contain at most 4 entries';
    END IF;
  END IF;

  UPDATE products SET
    title           = CASE WHEN p_patch ? 'title'           THEN btrim(p_patch->>'title')                        ELSE title END,
    subtitle        = CASE WHEN p_patch ? 'subtitle'        THEN COALESCE(p_patch->>'subtitle', '')               ELSE subtitle END,
    description     = CASE WHEN p_patch ? 'description'     THEN COALESCE(p_patch->>'description', '')            ELSE description END,
    description_doc = CASE WHEN p_patch ? 'description_doc' THEN p_patch->'description_doc'                       ELSE description_doc END,
    cover_image_url = CASE WHEN p_patch ? 'cover_image_url' THEN COALESCE(p_patch->>'cover_image_url', '')        ELSE cover_image_url END,
    cover_images    = CASE WHEN p_patch ? 'cover_images'    THEN COALESCE(p_patch->'cover_images', '[]'::jsonb)   ELSE cover_images END,
    gallery_images  = CASE WHEN p_patch ? 'gallery_images'  THEN COALESCE(p_patch->'gallery_images', '[]'::jsonb) ELSE gallery_images END,
    category        = CASE WHEN p_patch ? 'category'        THEN COALESCE(NULLIF(btrim(p_patch->>'category'), ''), 'general') ELSE category END,
    tags            = CASE WHEN p_patch ? 'tags' THEN COALESCE(
                            ARRAY(SELECT jsonb_array_elements_text(p_patch->'tags')),
                            '{}'::text[]
                          ) ELSE tags END,
    status          = CASE WHEN p_patch ? 'status'      THEN btrim(p_patch->>'status')                            ELSE status END,
    sort_weight     = CASE WHEN p_patch ? 'sort_weight' THEN COALESCE((p_patch->>'sort_weight')::integer, sort_weight) ELSE sort_weight END,
    sale_mode       = CASE WHEN p_patch ? 'sale_mode'   THEN btrim(p_patch->>'sale_mode')                         ELSE sale_mode END
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_update_product(uuid, jsonb, text[]) TO authenticated;