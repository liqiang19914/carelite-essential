
-- ====================================================================
-- 1.B.1 商城闭环：orders 表 + 6 个 SECURITY DEFINER RPC + 2 条 RLS SELECT 策略
-- 单商品订单（无 cart）+ 服务端价格快照（杜绝客户端篡改）+ paid 时间 FOR UPDATE 扣库存
-- ====================================================================

-- =========================================================
-- 1. orders 表
-- =========================================================
CREATE TABLE orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  out_trade_no TEXT NOT NULL UNIQUE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  product_id UUID REFERENCES products(id) ON DELETE SET NULL,
  sku_id UUID REFERENCES product_skus(id) ON DELETE SET NULL,

  -- 快照
  product_title_snapshot TEXT NOT NULL,
  cover_image_snapshot TEXT NOT NULL DEFAULT '',
  unit_price_cents INTEGER NOT NULL CHECK (unit_price_cents >= 0),
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  total_amount_cents INTEGER NOT NULL CHECK (total_amount_cents >= 0),
  product_source_type_snapshot TEXT NOT NULL CHECK (product_source_type_snapshot IN ('platform','manager')),
  owner_manager_id_snapshot UUID,

  -- 状态
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','paid','cancelled','closed','refunding','refunded')),
  preferred_payment_method TEXT CHECK (preferred_payment_method IN ('wechat','alipay')),
  payment_method TEXT CHECK (payment_method IN ('wechat','alipay')),
  trade_no TEXT NOT NULL DEFAULT '',
  paid_amount_cents INTEGER,
  stock_decremented BOOLEAN NOT NULL DEFAULT false,
  manual_refund_required BOOLEAN NOT NULL DEFAULT false,
  refund_amount_cents INTEGER,
  refund_reason TEXT NOT NULL DEFAULT '',

  -- 收货信息
  contact_name TEXT NOT NULL,
  contact_phone TEXT NOT NULL,
  shipping_province TEXT NOT NULL,
  shipping_city TEXT NOT NULL,
  shipping_district TEXT NOT NULL,
  shipping_address_detail TEXT NOT NULL,
  remark TEXT NOT NULL DEFAULT '',

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  paid_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  closed_at TIMESTAMPTZ,
  refunded_at TIMESTAMPTZ
);

COMMENT ON TABLE orders IS '商城订单表（1.B.1）：单商品订单 + 服务端价格快照 + paid 时间扣库存';
COMMENT ON COLUMN orders.out_trade_no IS '客户端生成的商户订单号，发给支付网关，UNIQUE 约束防重';
COMMENT ON COLUMN orders.product_source_type_snapshot IS '商品来源快照 platform/manager，预留未来 B2B2C 分润';
COMMENT ON COLUMN orders.owner_manager_id_snapshot IS '管理师 ID 快照，预留 B2B2C 分润';
COMMENT ON COLUMN orders.preferred_payment_method IS '用户在收银台选择的支付方式 wechat/alipay';
COMMENT ON COLUMN orders.payment_method IS '网关回调实际确认的支付方式';
COMMENT ON COLUMN orders.manual_refund_required IS '库存超卖 race 时打的标，需人工退款';

CREATE INDEX idx_orders_user_created ON orders (user_id, created_at DESC);
CREATE INDEX idx_orders_status_created ON orders (status, created_at DESC);
CREATE INDEX idx_orders_product ON orders (product_id) WHERE product_id IS NOT NULL;

CREATE TRIGGER orders_set_updated_at_trigger
BEFORE UPDATE ON orders
FOR EACH ROW
EXECUTE FUNCTION public.shop_set_updated_at();

-- =========================================================
-- 2. RLS 策略：仅 SELECT 直放；INSERT/UPDATE 全走 SECURITY DEFINER RPC
-- =========================================================
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY "orders_user_select_own"
  ON orders FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "orders_admin_select_all"
  ON orders FOR SELECT
  USING (public.is_admin(auth.uid()));

-- =========================================================
-- 3. get_active_product_detail_for_link
--    按 product_id 精确返回 active 商品 + 默认 SKU（含 manager 私域 active 商品）
--    用于 share link 场景：链接持有者已登录但不在 share_grants 列表中也能看到
-- =========================================================
CREATE OR REPLACE FUNCTION public.get_active_product_detail_for_link(
  p_product_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
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

  SELECT * INTO v_sku
    FROM product_skus
    WHERE product_id = v_product.id AND is_default = true
    LIMIT 1;

  RETURN jsonb_build_object(
    'product', to_jsonb(v_product),
    'default_sku', CASE WHEN v_sku.id IS NULL THEN NULL ELSE to_jsonb(v_sku) END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_product_detail_for_link(UUID) TO authenticated;

COMMENT ON FUNCTION public.get_active_product_detail_for_link(UUID)
  IS '分享链接专用：按 product_id 精确返回 active 商品 + 默认 SKU，包含 manager 私域 active 商品（不依赖 can_view_product 授权链）';

-- =========================================================
-- 4. create_shop_order
--    校验 + 价格快照 + 插入 pending 订单
-- =========================================================
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

  -- 默认 SKU 校验
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

  -- 服务端计算总金额（防客户端篡改）
  v_total := v_sku.price_cents * p_quantity;

  -- 插入 pending 订单
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

GRANT EXECUTE ON FUNCTION public.create_shop_order(
  TEXT, UUID, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) TO authenticated;

COMMENT ON FUNCTION public.create_shop_order(
  TEXT, UUID, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) IS '创建商城订单（pending）：服务端读价格快照 + 收货信息校验 + 库存软校验（硬校验在 paid 时）';

-- =========================================================
-- 5. user_cancel_shop_order
--    仅 owner 取消自己的 pending 订单
-- =========================================================
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

GRANT EXECUTE ON FUNCTION public.user_cancel_shop_order(TEXT) TO authenticated;

COMMENT ON FUNCTION public.user_cancel_shop_order(TEXT)
  IS '用户取消自己的 pending 订单（非 pending 状态返 error）';

-- =========================================================
-- 6. mark_order_paid_from_gateway
--    payment-notify 回调用 service_role 调
--    FOR UPDATE 锁订单 + SKU；幂等；库存不足则 close + manual_refund_required=true
-- =========================================================
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

  -- 幂等：非 pending 直接返回（已 paid / cancelled / closed / refunded）
  IF v_order.status <> 'pending' THEN
    RETURN v_order;
  END IF;

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
        manual_refund_required = true
    WHERE id = v_order.id
    RETURNING * INTO v_order;

  RETURN v_order;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_order_paid_from_gateway(TEXT, TEXT, INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_order_paid_from_gateway(TEXT, TEXT, INTEGER, TEXT) TO service_role;

COMMENT ON FUNCTION public.mark_order_paid_from_gateway(TEXT, TEXT, INTEGER, TEXT)
  IS 'payment-notify 回调专用：FOR UPDATE 锁订单/SKU，幂等扣库存，库存不足则关闭订单 + 人工退款标';

-- =========================================================
-- 7. mark_order_refunded_from_gateway
--    payment-refund-notify 回调用 service_role 调；幂等
-- =========================================================
CREATE OR REPLACE FUNCTION public.mark_order_refunded_from_gateway(
  p_out_trade_no  TEXT,
  p_refund_amount INTEGER,
  p_reason        TEXT
) RETURNS orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order orders;
BEGIN
  SELECT * INTO v_order
    FROM orders
    WHERE out_trade_no = p_out_trade_no
    FOR UPDATE;

  IF NOT FOUND THEN
    -- 静默：log + 返 NULL 让回调端返 success
    RAISE NOTICE 'refund notify for missing order: %', p_out_trade_no;
    RETURN NULL;
  END IF;

  -- 幂等：已经 refunded 直接返回
  IF v_order.status = 'refunded' THEN
    RETURN v_order;
  END IF;

  -- 仅 paid / closed / refunding 允许标 refunded
  IF v_order.status NOT IN ('paid','closed','refunding') THEN
    RAISE NOTICE 'refund notify ignored, order status=%', v_order.status;
    RETURN v_order;
  END IF;

  UPDATE orders
    SET status = 'refunded',
        refunded_at = NOW(),
        refund_amount_cents = p_refund_amount,
        refund_reason = COALESCE(p_reason, '')
    WHERE id = v_order.id
    RETURNING * INTO v_order;

  RETURN v_order;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_order_refunded_from_gateway(TEXT, INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_order_refunded_from_gateway(TEXT, INTEGER, TEXT) TO service_role;

COMMENT ON FUNCTION public.mark_order_refunded_from_gateway(TEXT, INTEGER, TEXT)
  IS 'payment-refund-notify 回调专用：幂等标 refunded，订单不存在/状态不符 RAISE NOTICE 不报错';
