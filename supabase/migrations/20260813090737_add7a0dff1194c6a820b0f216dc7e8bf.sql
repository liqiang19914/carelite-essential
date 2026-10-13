-- 修复1：商品详情 fallback 对所有私域商品都校验可见性，不再只拦积分商品
CREATE OR REPLACE FUNCTION public.get_active_product_detail_for_link(p_product_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid     UUID := auth.uid();
  v_product products;
  v_sku     product_skus;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden: not authenticated';
  END IF;

  SELECT * INTO v_product FROM products WHERE id = p_product_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'product not found';
  END IF;

  IF v_product.status <> 'active' THEN
    RAISE EXCEPTION 'product not active';
  END IF;

  -- 私域商品（现金/积分一律）必须过可见性闸门，否则知道 UUID 就能跨商户读详情
  IF v_product.source_type = 'manager'
     AND NOT can_view_product(p_product_id, v_uid) THEN
    RAISE EXCEPTION 'forbidden: product not visible';
  END IF;

  SELECT * INTO v_sku
    FROM product_skus
    WHERE product_id = v_product.id AND is_default = true
    LIMIT 1;

  RETURN jsonb_build_object(
    'product', to_jsonb(v_product),
    'default_sku', CASE WHEN v_sku.id IS NULL THEN NULL ELSE to_jsonb(v_sku) END
  );
END;
$function$;