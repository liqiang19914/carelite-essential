-- 门店资料扩展：地址 + 门头照片（存量门店不受影响，默认空）
ALTER TABLE public.stores
  ADD COLUMN IF NOT EXISTS address TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS storefront_image_url TEXT NOT NULL DEFAULT '';

ALTER TABLE public.stores
  ADD CONSTRAINT stores_address_length_check CHECK (char_length(address) <= 200);

-- 重建 update_store_profile（新签名 7 参：+ 地址 + 门头照）
DROP FUNCTION IF EXISTS public.update_store_profile(UUID, TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.update_store_profile(
  p_store_id UUID,
  p_name TEXT,
  p_phone TEXT,
  p_receipt_qr_url TEXT,
  p_payment_merchant_no TEXT,
  p_address TEXT,
  p_storefront_image_url TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_store public.stores%ROWTYPE;
  v_name TEXT := btrim(COALESCE(p_name, ''));
  v_phone TEXT := btrim(COALESCE(p_phone, ''));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_store FROM public.stores WHERE id = p_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '门店不存在' USING ERRCODE = '22023';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS DISTINCT FROM v_store.root_manager_id
     AND v_store.operator_user_id IS DISTINCT FROM v_uid
     AND NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '你没有管理这家门店的权限' USING ERRCODE = '42501';
  END IF;

  IF v_name = '' OR char_length(v_name) > 60 THEN
    RAISE EXCEPTION '门店名称不能为空且不超过 60 字' USING ERRCODE = '22023';
  END IF;
  IF v_phone !~ '^1[3-9][0-9]{9}$' THEN
    RAISE EXCEPTION '手机号格式不正确' USING ERRCODE = '22023';
  END IF;
  IF char_length(COALESCE(p_receipt_qr_url, '')) > 2000 THEN
    RAISE EXCEPTION '收款码链接过长' USING ERRCODE = '22023';
  END IF;
  IF char_length(COALESCE(p_payment_merchant_no, '')) > 64 THEN
    RAISE EXCEPTION '商户号登记信息过长' USING ERRCODE = '22023';
  END IF;
  IF char_length(COALESCE(p_address, '')) > 200 THEN
    RAISE EXCEPTION '门店地址最多 200 字' USING ERRCODE = '22023';
  END IF;
  IF char_length(COALESCE(p_storefront_image_url, '')) > 2000 THEN
    RAISE EXCEPTION '门头照片链接过长' USING ERRCODE = '22023';
  END IF;

  UPDATE public.stores
     SET name = v_name,
         phone = v_phone,
         receipt_qr_url = COALESCE(p_receipt_qr_url, receipt_qr_url),
         payment_merchant_no = COALESCE(p_payment_merchant_no, payment_merchant_no),
         address = COALESCE(p_address, address),
         storefront_image_url = COALESCE(p_storefront_image_url, storefront_image_url),
         updated_at = now()
   WHERE id = v_store.id;

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.update_store_profile(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_store_profile(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- 商户企业门店列表回传新字段
CREATE OR REPLACE FUNCTION public.list_enterprise_stores()
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_items JSON;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '只有商户账号可以管理门店' USING ERRCODE = '42501';
  END IF;

  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT s.id, s.short_code, s.name, s.phone, s.status,
           s.receipt_qr_url, s.payment_merchant_no, s.created_source,
           s.address, s.storefront_image_url,
           s.disabled_at, s.created_at,
           (s.operator_user_id IS NULL) AS awaiting_claim,
           op.nickname AS operator_nickname
    FROM public.stores s
    LEFT JOIN public.profiles op ON op.id = s.operator_user_id
    WHERE s.root_manager_id = v_root
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_stores() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_enterprise_stores() TO authenticated;

-- 公开短码解析回传地址/门头/电话
CREATE OR REPLACE FUNCTION public.get_public_store_by_code(p_code TEXT)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_store public.stores%ROWTYPE;
BEGIN
  IF p_code IS NULL OR btrim(p_code) = '' THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_store FROM public.stores WHERE short_code = btrim(p_code);
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN json_build_object(
    'id', v_store.id,
    'short_code', v_store.short_code,
    'name', v_store.name,
    'phone', v_store.phone,
    'status', v_store.status,
    'root_manager_id', v_store.root_manager_id,
    'receipt_qr_url', v_store.receipt_qr_url,
    'address', v_store.address,
    'storefront_image_url', v_store.storefront_image_url,
    'disabled_at', v_store.disabled_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_store_by_code(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_store_by_code(TEXT) TO anon, authenticated;

-- 门店商城列表回传地址/门头/电话
CREATE OR REPLACE FUNCTION public.get_store_products(p_store_code TEXT)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_store public.stores%ROWTYPE;
  v_items JSON;
  v_root_on BOOLEAN;
BEGIN
  IF p_store_code IS NULL OR btrim(p_store_code) = '' THEN
    RETURN json_build_object('store', NULL, 'items', '[]'::JSON, 'reason', 'missing_code');
  END IF;
  SELECT * INTO v_store FROM public.stores WHERE short_code = btrim(p_store_code);
  IF NOT FOUND THEN
    RETURN json_build_object('store', NULL, 'items', '[]'::JSON, 'reason', 'not_found');
  END IF;

  SELECT public._store_module_on(v_store.root_manager_id) INTO v_root_on;
  IF v_store.status <> 'active' OR NOT COALESCE(v_root_on, false) THEN
    RETURN json_build_object(
      'store', json_build_object(
        'id', v_store.id, 'short_code', v_store.short_code,
        'name', v_store.name, 'phone', v_store.phone, 'status', v_store.status,
        'root_manager_id', v_store.root_manager_id,
        'receipt_qr_url', v_store.receipt_qr_url,
        'address', v_store.address,
        'storefront_image_url', v_store.storefront_image_url,
        'disabled_at', v_store.disabled_at
      ),
      'items', '[]'::JSON,
      'reason', 'store_disabled'
    );
  END IF;

  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT p.id, p.title, p.subtitle, p.cover_image_url,
           p.category, p.tags, p.sales_count,
           sku.price_cents, sku.stock, sku.id AS sku_id,
           p.requires_shipping, p.store_only
    FROM public.store_product_grants g
    JOIN public.products p ON p.id = g.product_id
    JOIN public.product_skus sku ON sku.product_id = p.id AND sku.is_default = true
    WHERE g.store_id = v_store.id
      AND g.is_enabled = true
      AND p.status = 'active'
      AND p.source_type = 'manager'
      AND p.sale_mode = 'cash'
      AND p.owner_manager_id IS NOT NULL
      AND public.get_enterprise_root_manager_id(p.owner_manager_id) = v_store.root_manager_id
      AND sku.is_active = true
      AND sku.stock > 0
  ) t;

  RETURN json_build_object(
    'store', json_build_object(
      'id', v_store.id, 'short_code', v_store.short_code,
      'name', v_store.name, 'phone', v_store.phone, 'status', v_store.status,
      'root_manager_id', v_store.root_manager_id,
      'receipt_qr_url', v_store.receipt_qr_url,
      'address', v_store.address,
      'storefront_image_url', v_store.storefront_image_url,
      'disabled_at', v_store.disabled_at
    ),
    'items', COALESCE(v_items, '[]'::JSON),
    'reason', 'ok'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_store_products(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_store_products(TEXT) TO anon, authenticated;

-- 门店商品详情回传地址/门头/电话
CREATE OR REPLACE FUNCTION public.get_store_product_detail(
  p_store_code TEXT,
  p_product_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_store public.stores%ROWTYPE;
  v_product public.products%ROWTYPE;
  v_sku public.product_skus%ROWTYPE;
  v_granted BOOLEAN;
BEGIN
  IF p_store_code IS NULL OR p_product_id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_store FROM public.stores WHERE short_code = btrim(p_store_code);
  IF NOT FOUND OR v_store.status <> 'active' THEN
    RETURN NULL;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.store_product_grants g
    WHERE g.store_id = v_store.id AND g.product_id = p_product_id AND g.is_enabled = true
  ) INTO v_granted;
  IF NOT COALESCE(v_granted, false) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_product FROM public.products
  WHERE id = p_product_id AND status = 'active'
    AND source_type = 'manager' AND sale_mode = 'cash';
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF public.get_enterprise_root_manager_id(v_product.owner_manager_id) IS DISTINCT FROM v_store.root_manager_id THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_sku FROM public.product_skus
  WHERE product_id = p_product_id AND is_default = true AND is_active = true
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN json_build_object(
    'store', json_build_object(
      'id', v_store.id, 'short_code', v_store.short_code, 'name', v_store.name,
      'phone', v_store.phone,
      'receipt_qr_url', v_store.receipt_qr_url, 'root_manager_id', v_store.root_manager_id,
      'address', v_store.address,
      'storefront_image_url', v_store.storefront_image_url
    ),
    'product', json_build_object(
      'id', v_product.id, 'title', v_product.title, 'subtitle', v_product.subtitle,
      'description', v_product.description, 'description_doc', v_product.description_doc,
      'cover_image_url', v_product.cover_image_url, 'gallery_images', v_product.gallery_images,
      'category', v_product.category, 'tags', v_product.tags,
      'sales_count', v_product.sales_count, 'requires_shipping', v_product.requires_shipping,
      'store_only', v_product.store_only,
      'sku_id', v_sku.id, 'price_cents', v_sku.price_cents, 'stock', v_sku.stock
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_store_product_detail(TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_store_product_detail(TEXT, UUID) TO anon, authenticated;