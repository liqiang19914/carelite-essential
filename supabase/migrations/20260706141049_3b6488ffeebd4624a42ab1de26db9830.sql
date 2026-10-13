CREATE OR REPLACE FUNCTION public.admin_create_product(
  p_title text,
  p_subtitle text DEFAULT ''::text,
  p_description text DEFAULT ''::text,
  p_cover_image_url text DEFAULT ''::text,
  p_gallery_images jsonb DEFAULT '[]'::jsonb,
  p_category text DEFAULT 'general'::text,
  p_tags text[] DEFAULT '{}'::text[],
  p_status text DEFAULT 'draft'::text,
  p_is_featured boolean DEFAULT false,
  p_sort_weight integer DEFAULT 0,
  p_cover_images jsonb DEFAULT NULL::jsonb,
  p_requires_shipping boolean DEFAULT true,
  p_virtual_card_code text DEFAULT NULL
)
 RETURNS products
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid           UUID := auth.uid();
  v_title         TEXT;
  v_cover_images  JSONB;
  v_card_code     TEXT;
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

  v_card_code := NULLIF(btrim(COALESCE(p_virtual_card_code, '')), '');
  IF v_card_code IS NOT NULL AND p_requires_shipping THEN
    RAISE EXCEPTION 'virtual card products must have requires_shipping = false';
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
    created_by,
    requires_shipping,
    virtual_card_code
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
    v_uid,
    COALESCE(p_requires_shipping, true),
    v_card_code
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_update_product(p_id uuid, p_patch jsonb)
 RETURNS products
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid           UUID := auth.uid();
  v_row           products;
  v_source        TEXT;
  v_title         TEXT;
  v_status        TEXT;
  v_cover_images  JSONB;
  v_unknown_key   TEXT;
  v_requires_shipping BOOLEAN;
  v_card_code     TEXT;
  v_allowed       CONSTANT TEXT[] := ARRAY[
    'title', 'subtitle', 'description',
    'cover_image_url', 'cover_images',
    'gallery_images',
    'category', 'tags',
    'status', 'is_featured', 'sort_weight',
    'requires_shipping', 'virtual_card_code'
  ];
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

  -- 未知 key 校验:防止前端 typo 或字段静默丢失更新
  SELECT k INTO v_unknown_key
  FROM jsonb_object_keys(p_patch) AS k
  WHERE k <> ALL(v_allowed)
  LIMIT 1;
  IF v_unknown_key IS NOT NULL THEN
    RAISE EXCEPTION 'unknown patch key: %', v_unknown_key;
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

  IF p_patch ? 'requires_shipping' OR p_patch ? 'virtual_card_code' THEN
    SELECT
      CASE WHEN p_patch ? 'requires_shipping' THEN (p_patch->>'requires_shipping')::boolean ELSE requires_shipping END,
      CASE WHEN p_patch ? 'virtual_card_code' THEN NULLIF(btrim(COALESCE(p_patch->>'virtual_card_code', '')), '') ELSE virtual_card_code END
    INTO v_requires_shipping, v_card_code
    FROM products WHERE id = p_id;

    IF v_card_code IS NOT NULL AND v_requires_shipping THEN
      RAISE EXCEPTION 'virtual card products must have requires_shipping = false';
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
    sort_weight     = CASE WHEN p_patch ? 'sort_weight'     THEN COALESCE((p_patch->>'sort_weight')::integer, sort_weight) ELSE sort_weight END,
    requires_shipping = CASE WHEN p_patch ? 'requires_shipping' THEN (p_patch->>'requires_shipping')::boolean ELSE requires_shipping END,
    virtual_card_code = CASE WHEN p_patch ? 'virtual_card_code' THEN NULLIF(btrim(COALESCE(p_patch->>'virtual_card_code', '')), '') ELSE virtual_card_code END
  WHERE id = p_id
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product not found';
  END IF;

  RETURN v_row;
END;
$function$;
