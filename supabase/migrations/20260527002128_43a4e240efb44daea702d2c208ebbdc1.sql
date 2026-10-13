
-- ====================================================================
-- 1.B.1 Hotfix-2：codex-review P1 三项修复
-- 1) mark_order_paid_from_gateway 加 amount 校验 + paid-after-cancel 兜底
-- 2) create_shop_order / user_cancel_shop_order 限制 role='user'
-- 3) orders.user_id FK CASCADE → RESTRICT（保留订单作为账务记录）
-- ====================================================================

-- ============ P1.3: FK CASCADE → RESTRICT ============
ALTER TABLE orders DROP CONSTRAINT orders_user_id_fkey;
ALTER TABLE orders ADD CONSTRAINT orders_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE RESTRICT;

-- ============ P1.1+P1.2: mark_order_paid_from_gateway 重写 ============
CREATE OR REPLACE FUNCTION public.mark_order_paid_from_gateway(
  p_out_trade_no    TEXT,
  p_trade_no        TEXT,
  p_paid_amount     INTEGER,
  p_payment_method  TEXT
) RETURNS orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order orders;
  v_sku   product_skus;
BEGIN
  -- 锁订单行
  SELECT * INTO v_order
    FROM orders
    WHERE out_trade_no = p_out_trade_no
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'order not found: %', p_out_trade_no;
  END IF;

  -- 已 paid/closed/refunding/refunded：真幂等，不再 mutate
  IF v_order.status IN ('paid', 'closed', 'refunding', 'refunded') THEN
    RETURN v_order;
  END IF;

  -- P1.1：金额校验。客户端不能控制最终 paid_amount = total_amount_cents
  -- 若金额不符（用户在网关被骗付了少额），关闭订单 + 标人工退款
  IF p_paid_amount IS NULL OR p_paid_amount <> v_order.total_amount_cents THEN
    UPDATE orders SET
      status = 'closed',
      closed_at = NOW(),
      payment_method = COALESCE(NULLIF(p_payment_method, ''), preferred_payment_method),
      trade_no = COALESCE(p_trade_no, ''),
      paid_amount_cents = COALESCE(p_paid_amount, 0),
      manual_refund_required = true,
      refund_reason = CASE
        WHEN refund_reason IS NULL OR refund_reason = ''
          THEN 'paid amount mismatch'
        ELSE refund_reason
      END
    WHERE id = v_order.id
    RETURNING * INTO v_order;
    RETURN v_order;
  END IF;

  -- P1.2：cancelled 状态下到达 paid callback → close + 人工退款（用户先取消又付款）
  IF v_order.status = 'cancelled' THEN
    UPDATE orders SET
      status = 'closed',
      closed_at = NOW(),
      payment_method = COALESCE(NULLIF(p_payment_method, ''), preferred_payment_method),
      trade_no = COALESCE(p_trade_no, ''),
      paid_amount_cents = p_paid_amount,
      manual_refund_required = true,
      refund_reason = CASE
        WHEN refund_reason IS NULL OR refund_reason = ''
          THEN 'paid after cancel'
        ELSE refund_reason
      END
    WHERE id = v_order.id
    RETURNING * INTO v_order;
    RETURN v_order;
  END IF;

  -- v_order.status = 'pending' 后续路径
  -- 锁 SKU 行（可能为 NULL：商品已被删）
  IF v_order.sku_id IS NOT NULL THEN
    SELECT * INTO v_sku
      FROM product_skus
      WHERE id = v_order.sku_id
      FOR UPDATE;
  END IF;

  -- 库存够 → 扣库存 + 增 sales_count + 订单 paid
  IF v_sku.id IS NOT NULL AND v_sku.stock >= v_order.quantity THEN
    UPDATE product_skus
      SET stock = stock - v_order.quantity
      WHERE id = v_sku.id;

    IF v_order.product_id IS NOT NULL THEN
      UPDATE products
        SET sales_count = sales_count + v_order.quantity
        WHERE id = v_order.product_id;
    END IF;

    UPDATE orders
      SET status = 'paid',
          paid_at = NOW(),
          payment_method = COALESCE(NULLIF(p_payment_method, ''), preferred_payment_method),
          trade_no = COALESCE(p_trade_no, ''),
          paid_amount_cents = p_paid_amount,
          stock_decremented = true
      WHERE id = v_order.id
      RETURNING * INTO v_order;

    RETURN v_order;
  END IF;

  -- 库存不足 / SKU 缺失 → 已付款但货没了 → 关闭订单 + 标记人工退款
  UPDATE orders
    SET status = 'closed',
        closed_at = NOW(),
        payment_method = COALESCE(NULLIF(p_payment_method, ''), preferred_payment_method),
        trade_no = COALESCE(p_trade_no, ''),
        paid_amount_cents = p_paid_amount,
        manual_refund_required = true,
        refund_reason = CASE
          WHEN refund_reason IS NULL OR refund_reason = ''
            THEN 'insufficient stock at payment'
          ELSE refund_reason
        END
    WHERE id = v_order.id
    RETURNING * INTO v_order;

  RETURN v_order;
END;
$$;

COMMENT ON FUNCTION public.mark_order_paid_from_gateway(TEXT, TEXT, INTEGER, TEXT)
  IS 'payment-notify 回调专用：金额校验 + paid-after-cancel 兜底 + FOR UPDATE 锁订单/SKU，幂等扣库存';

-- ============ P2.2: create_shop_order 限制 role='user' ============
CREATE OR REPLACE FUNCTION public.create_shop_order(
  p_out_trade_no              TEXT,
  p_product_id                UUID,
  p_quantity                  INTEGER,
  p_preferred_payment_method  TEXT,
  p_contact_name              TEXT,
  p_contact_phone             TEXT,
  p_province                  TEXT,
  p_city                      TEXT,
  p_district                  TEXT,
  p_address_detail            TEXT,
  p_remark                    TEXT DEFAULT ''
) RETURNS orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_product products;
  v_sku     product_skus;
  v_row     orders;
  v_total   INTEGER;
  v_otn     TEXT;
  v_name    TEXT;
  v_phone   TEXT;
  v_prov    TEXT;
  v_city    TEXT;
  v_dist    TEXT;
  v_addr    TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden: not authenticated';
  END IF;

  -- P2.2：只允许 C 端 role='user' 用户下单
  IF NOT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = v_uid AND role = 'user' AND is_disabled = false
  ) THEN
    RAISE EXCEPTION 'forbidden: only end users can place orders';
  END IF;

  -- 字段格式校验
  v_otn := btrim(COALESCE(p_out_trade_no, ''));
  IF v_otn = '' OR char_length(v_otn) > 64 THEN
    RAISE EXCEPTION 'invalid out_trade_no';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 9999 THEN
    RAISE EXCEPTION 'quantity must be between 1 and 9999';
  END IF;
  IF p_preferred_payment_method NOT IN ('wechat','alipay') THEN
    RAISE EXCEPTION 'preferred_payment_method must be wechat or alipay';
  END IF;

  v_name := btrim(COALESCE(p_contact_name, ''));
  v_phone := btrim(COALESCE(p_contact_phone, ''));
  v_prov := btrim(COALESCE(p_province, ''));
  v_city := btrim(COALESCE(p_city, ''));
  v_dist := btrim(COALESCE(p_district, ''));
  v_addr := btrim(COALESCE(p_address_detail, ''));

  IF v_name = '' OR char_length(v_name) > 50 THEN
    RAISE EXCEPTION 'invalid contact_name';
  END IF;
  IF v_phone !~ '^1[3-9][0-9]{9}$' THEN
    RAISE EXCEPTION 'invalid contact_phone';
  END IF;
  IF v_prov = '' OR char_length(v_prov) > 30 THEN
    RAISE EXCEPTION 'invalid province';
  END IF;
  IF v_city = '' OR char_length(v_city) > 30 THEN
    RAISE EXCEPTION 'invalid city';
  END IF;
  IF v_dist = '' OR char_length(v_dist) > 30 THEN
    RAISE EXCEPTION 'invalid district';
  END IF;
  IF v_addr = '' OR char_length(v_addr) > 200 THEN
    RAISE EXCEPTION 'invalid address_detail';
  END IF;
  IF char_length(COALESCE(p_remark, '')) > 200 THEN
    RAISE EXCEPTION 'remark too long (max 200)';
  END IF;

  -- 商品校验
  SELECT * INTO v_product FROM products WHERE id = p_product_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'product not found';
  END IF;
  IF v_product.status <> 'active' THEN
    RAISE EXCEPTION 'product not active';
  END IF;

  SELECT * INTO v_sku
    FROM product_skus
    WHERE product_id = p_product_id AND is_default = true
    LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'default sku not found';
  END IF;
  IF v_sku.is_active = false THEN
    RAISE EXCEPTION 'sku not active';
  END IF;
  IF v_sku.stock < p_quantity THEN
    RAISE EXCEPTION 'insufficient stock';
  END IF;
  IF v_sku.price_cents <= 0 THEN
    RAISE EXCEPTION 'product price not configured';
  END IF;

  v_total := v_sku.price_cents * p_quantity;

  INSERT INTO orders (
    out_trade_no, user_id, product_id, sku_id,
    product_title_snapshot, cover_image_snapshot,
    unit_price_cents, quantity, total_amount_cents,
    product_source_type_snapshot, owner_manager_id_snapshot,
    status, preferred_payment_method,
    contact_name, contact_phone, shipping_province, shipping_city,
    shipping_district, shipping_address_detail, remark
  ) VALUES (
    v_otn, v_uid, v_product.id, v_sku.id,
    v_product.title, COALESCE(v_product.cover_image_url, ''),
    v_sku.price_cents, p_quantity, v_total,
    v_product.source_type, v_product.owner_manager_id,
    'pending', p_preferred_payment_method,
    v_name, v_phone, v_prov, v_city,
    v_dist, v_addr, COALESCE(p_remark, '')
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

-- ============ P2.2: user_cancel_shop_order 限制 role='user' ============
CREATE OR REPLACE FUNCTION public.user_cancel_shop_order(
  p_out_trade_no TEXT
) RETURNS orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_row orders;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden: not authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = v_uid AND role = 'user' AND is_disabled = false
  ) THEN
    RAISE EXCEPTION 'forbidden: only end users can cancel orders';
  END IF;

  UPDATE orders
    SET status = 'cancelled',
        cancelled_at = NOW()
    WHERE out_trade_no = p_out_trade_no
      AND user_id = v_uid
      AND status = 'pending'
    RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'order not found or not cancellable';
  END IF;

  RETURN v_row;
END;
$$;
