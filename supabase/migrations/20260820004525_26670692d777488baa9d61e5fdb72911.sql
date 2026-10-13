-- 二次审查修复
-- 1. 店面商品详情 RPC：带当前店校验，本店只能看本店商品、平台商品只在平台主店
-- 2. _can_order_product_in_shop 给 service_role 补回执行权（运维/Edge Function 通道）

CREATE OR REPLACE FUNCTION public.get_storefront_product_detail(
  p_product_id uuid,
  p_shop_root uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_product public.products;
  v_root    uuid;
  v_sku     jsonb;
BEGIN
  SELECT * INTO v_product
  FROM public.products
  WHERE id = p_product_id AND status = 'active';
  IF v_product.id IS NULL THEN
    RETURN NULL;
  END IF;

  -- 非空店铺参数先解析企业根，解析不出 = 无效店铺，直接空
  IF p_shop_root IS NOT NULL THEN
    v_root := public.get_enterprise_root_manager_id(p_shop_root);
    IF v_root IS NULL THEN
      RETURN NULL;
    END IF;
  END IF;

  -- 平台商品只在平台主店（无店上下文）可见
  IF v_product.source_type = 'platform' AND v_root IS NOT NULL THEN
    RETURN NULL;
  END IF;

  -- 商户商品只在归属店可见
  IF v_product.source_type = 'manager' THEN
    IF v_root IS NULL
       OR v_product.owner_manager_id IS NULL
       OR public.get_enterprise_root_manager_id(v_product.owner_manager_id) IS DISTINCT FROM v_root THEN
      RETURN NULL;
    END IF;
  END IF;

  SELECT jsonb_agg(to_jsonb(s)) INTO v_sku
  FROM public.product_skus s
  WHERE s.product_id = v_product.id
    AND s.is_default = true
    AND s.is_active = true;

  RETURN jsonb_build_object(
    'product', to_jsonb(v_product),
    'default_sku', COALESCE(v_sku -> 0, NULL)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_storefront_product_detail(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_storefront_product_detail(uuid, uuid) TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public._can_order_product_in_shop(uuid, uuid, uuid) TO service_role;