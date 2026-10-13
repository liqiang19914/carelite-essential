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
        'name', v_store.name, 'status', v_store.status,
        'root_manager_id', v_store.root_manager_id,
        'receipt_qr_url', v_store.receipt_qr_url, 'disabled_at', v_store.disabled_at
      ),
      'items', '[]'::JSON,
      'reason', 'store_disabled'
    );
  END IF;

  SELECT json_agg(t) INTO v_items
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
    ORDER BY p.created_at DESC
  ) t;

  RETURN json_build_object(
    'store', json_build_object(
      'id', v_store.id, 'short_code', v_store.short_code,
      'name', v_store.name, 'status', v_store.status,
      'root_manager_id', v_store.root_manager_id,
      'receipt_qr_url', v_store.receipt_qr_url, 'disabled_at', v_store.disabled_at
    ),
    'items', COALESCE(v_items, '[]'::JSON),
    'reason', 'ok'
  );
END;
$function$;