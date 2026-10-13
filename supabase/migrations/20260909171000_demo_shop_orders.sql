-- 演示订单只供商户演示使用：不进入支付、库存或普通用户订单视图。
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_orders_demo_manager_created
  ON public.orders (shop_manager_id_snapshot, created_at DESC, id DESC)
  WHERE is_demo = true;

CREATE OR REPLACE FUNCTION public.manager_create_demo_shop_orders(
  p_count integer DEFAULT 6
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_scope jsonb := public._resolve_manager_scope(auth.uid());
  v_root uuid := (v_scope->>'root_id')::uuid;
  v_owners uuid[] := public._manager_visible_owner_ids(auth.uid(), v_root, (v_scope->>'is_root')::boolean);
  v_count integer := LEAST(GREATEST(COALESCE(p_count, 6), 1), 20);
  v_inserted integer := 0;
  v_product record;
  s record;
BEGIN
  IF auth.uid() IS NULL OR v_root IS NULL THEN RAISE EXCEPTION '未登录或无商户权限'; END IF;

  -- 重复点击只刷新演示批次，不触碰任何真实订单。
  DELETE FROM public.orders WHERE is_demo = true AND shop_manager_id_snapshot = v_root;

  FOR v_product IN
    SELECT prod.* FROM public.products prod
    WHERE prod.status = 'active'
      AND (prod.owner_manager_id = ANY(v_owners) OR prod.owner_manager_id = v_root)
    ORDER BY prod.sort_weight DESC, prod.created_at DESC
    LIMIT v_count
  LOOP
    SELECT * INTO s FROM public.product_skus
    WHERE product_id = v_product.id AND is_default = true AND is_active = true
    ORDER BY created_at ASC LIMIT 1;

    INSERT INTO public.orders (
      out_trade_no, user_id, product_id, sku_id, product_title_snapshot,
      cover_image_snapshot, unit_price_cents, quantity, total_amount_cents,
      product_source_type_snapshot, owner_manager_id_snapshot, status,
      payment_method, trade_no, paid_amount_cents, stock_decremented,
      manual_refund_required, contact_name, contact_phone, shipping_province,
      shipping_city, shipping_district, shipping_address_detail, remark,
      paid_at, requires_shipping_snapshot, fulfillment_status,
      fulfillment_manager_id_snapshot, shop_manager_id_snapshot, is_demo
    ) VALUES (
      'DEMO-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12)),
      auth.uid(), v_product.id, s.id, v_product.title, v_product.cover_image_url,
      COALESCE(s.price_cents, 0), 1, COALESCE(s.price_cents, 0),
      v_product.source_type, v_product.owner_manager_id, 'paid', NULL, '',
      COALESCE(s.price_cents, 0), false, false,
      CASE v_inserted % 2 WHEN 0 THEN '演示客户·林女士' ELSE '演示客户·周先生' END,
      '1380000' || lpad((v_inserted + 1)::text, 4, '0'),
      '', '', '', '', '演示订单：不产生支付与履约动作', now() - (v_inserted || ' days')::interval,
      false, 'not_required', NULL, v_root, true
    );
    v_inserted := v_inserted + 1;
  END LOOP;
  RETURN v_inserted;
END;
$$;

REVOKE ALL ON FUNCTION public.manager_create_demo_shop_orders(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.manager_create_demo_shop_orders(integer) TO authenticated;

-- 普通用户即使与演示管理员共用账号，也永远看不到演示行。
DROP POLICY IF EXISTS orders_user_select_own ON public.orders;
CREATE POLICY orders_user_select_own ON public.orders FOR SELECT
  USING (auth.uid() = user_id AND is_demo = false);

