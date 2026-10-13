-- 457：店面商品列表透传 scene_code（10 位商品码），商城列表到详情的外发导航才能用短码路径

CREATE OR REPLACE FUNCTION public.get_storefront_products(p_shop_root uuid DEFAULT NULL::uuid, p_sale_mode text DEFAULT NULL::text, p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_root  uuid;
  v_mode  text;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
  v_out   jsonb;
BEGIN
  v_mode := NULLIF(btrim(COALESCE(p_sale_mode, '')), '');
  IF v_mode IS NOT NULL AND v_mode NOT IN ('cash', 'points') THEN
    RAISE EXCEPTION 'invalid sale_mode: %', v_mode USING ERRCODE = '22023';
  END IF;

  -- 平台主店：只出平台自营 active 商品
  IF p_shop_root IS NULL THEN
    SELECT COALESCE(jsonb_agg(t.row_json), '[]'::jsonb) INTO v_out
    FROM (
      SELECT jsonb_build_object(
        'id', p.id, 'scene_code', p.scene_code, 'title', p.title, 'subtitle', p.subtitle,
        'description', p.description, 'description_doc', p.description_doc,
        'cover_image_url', p.cover_image_url, 'cover_images', p.cover_images,
        'gallery_images', p.gallery_images, 'category', p.category, 'tags', p.tags,
        'status', p.status, 'source_type', p.source_type, 'sale_mode', p.sale_mode,
        'owner_manager_id', p.owner_manager_id,
        'is_featured', p.is_featured, 'sort_weight', p.sort_weight,
        'requires_shipping', p.requires_shipping, 'virtual_card_code', p.virtual_card_code,
        'view_count', p.view_count, 'sales_count', p.sales_count,
        'store_only', COALESCE(p.store_only, false),
        'created_at', p.created_at, 'updated_at', p.updated_at,
        'product_skus', COALESCE((
          SELECT jsonb_agg(to_jsonb(s))
          FROM public.product_skus s
          WHERE s.product_id = p.id AND s.is_default = true AND s.is_active = true
        ), '[]'::jsonb)
      ) AS row_json
      FROM public.products p
      WHERE p.source_type = 'platform'
        AND p.status = 'active'
        AND (v_mode IS NULL OR COALESCE(p.sale_mode, 'cash') = v_mode)
        AND (p.virtual_card_code IS NULL OR p.virtual_card_code = 'consumer_health365')
      ORDER BY p.is_featured DESC, p.sort_weight DESC, p.created_at DESC
      LIMIT v_limit
    ) t;
    RETURN v_out;
  END IF;

  -- 商户店：解析企业根；未认证或已禁用的商户直接空店
  v_root := public.get_enterprise_root_manager_id(p_shop_root);
  IF v_root IS NULL OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(t.row_json), '[]'::jsonb) INTO v_out
  FROM (
    SELECT jsonb_build_object(
      'id', p.id, 'scene_code', p.scene_code, 'title', p.title, 'subtitle', p.subtitle,
      'description', p.description, 'description_doc', p.description_doc,
      'cover_image_url', p.cover_image_url, 'cover_images', p.cover_images,
      'gallery_images', p.gallery_images, 'category', p.category, 'tags', p.tags,
      'status', p.status, 'source_type', p.source_type, 'sale_mode', p.sale_mode,
      'owner_manager_id', p.owner_manager_id,
      'is_featured', p.is_featured, 'sort_weight', p.sort_weight,
      'requires_shipping', p.requires_shipping, 'virtual_card_code', p.virtual_card_code,
      'view_count', p.view_count, 'sales_count', p.sales_count,
      'store_only', COALESCE(p.store_only, false),
      'created_at', p.created_at, 'updated_at', p.updated_at,
      'product_skus', COALESCE((
        SELECT jsonb_agg(to_jsonb(s))
        FROM public.product_skus s
        WHERE s.product_id = p.id AND s.is_default = true AND s.is_active = true
      ), '[]'::jsonb)
    ) AS row_json
    FROM public.products p
    WHERE p.source_type = 'manager'
      AND p.status = 'active'
      AND p.owner_manager_id IS NOT NULL
      AND public.get_enterprise_root_manager_id(p.owner_manager_id) = v_root
      AND (v_mode IS NULL OR COALESCE(p.sale_mode, 'cash') = v_mode)
      AND (p.virtual_card_code IS NULL OR p.virtual_card_code = 'consumer_health365')
      AND (
        COALESCE(p.sale_mode, 'cash') <> 'points'
        OR EXISTS (
          SELECT 1 FROM public.merchant_module_grants g
          WHERE g.manager_id = v_root
            AND g.module_key = 'points_exchange'
            AND g.grant_status = 'granted'
            AND g.is_enabled = TRUE
        )
      )
    ORDER BY p.is_featured DESC, p.sort_weight DESC, p.created_at DESC
    LIMIT v_limit
  ) t;

  RETURN v_out;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.get_storefront_products(uuid, text, integer) TO anon, authenticated;