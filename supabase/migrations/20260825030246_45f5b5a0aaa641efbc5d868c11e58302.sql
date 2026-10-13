DROP FUNCTION IF EXISTS public._order_total_provisional();

CREATE OR REPLACE FUNCTION public.create_shop_order(
  p_out_trade_no text,
  p_product_id uuid,
  p_quantity integer,
  p_preferred_payment_method text,
  p_contact_name text,
  p_contact_phone text,
  p_province text,
  p_city text,
  p_district text,
  p_address_detail text,
  p_remark text DEFAULT ''::text,
  p_shop_manager_id uuid DEFAULT NULL::uuid,
  p_promoter_code text DEFAULT NULL::text
)
RETURNS orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
  v_shop_root UUID;
  v_context_root UUID;
  v_promoter_id UUID;
  v_promoter_code_raw TEXT;
  v_rule    promotion_rules;
  v_comm    INTEGER := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden: not authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = v_uid AND role = 'user' AND is_disabled = false
  ) THEN
    RAISE EXCEPTION 'forbidden: only end users can place orders';
  END IF;

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

  -- 下单上下文：前端报的「当前所在店」只作在哪买的校验，订单归属以商品为准
  v_context_root := public._resolve_order_shop_root(p_shop_manager_id);

  SELECT * INTO v_product FROM products WHERE id = p_product_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'product not found';
  END IF;
  IF v_product.status <> 'active' THEN
    RAISE EXCEPTION 'product not active';
  END IF;

  -- 可购校验：商品归属店必须与当前所在店一致（A 店买不到 B 店的货）
  IF NOT public._can_order_product_in_shop(p_product_id, v_uid, v_context_root) THEN
    RAISE EXCEPTION '这件商品当前不向你开放购买';
  END IF;

  -- 订单归属以商品实际归属为准：商户商品→其企业根；平台商品→平台主店（NULL）
  IF v_product.source_type = 'manager' THEN
    v_shop_root := public.get_enterprise_root_manager_id(v_product.owner_manager_id);
  ELSE
    v_shop_root := NULL;
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

  -- 推广归因：只认普通现金商品（积分兑换与虚拟卡不参与返佣）。
  -- 校验失败的推广参数一律静默忽略（营销加成不阻断交易），绝不乱入账。
  v_promoter_code_raw := btrim(COALESCE(p_promoter_code, ''));
  IF v_promoter_code_raw <> '' AND v_shop_root IS NOT NULL
     AND COALESCE(v_product.sale_mode, 'cash') = 'cash'
     AND COALESCE(v_product.virtual_card_code, '') = '' THEN
    SELECT pc.promoter_id INTO v_promoter_id
    FROM public.promotion_codes pc
    WHERE pc.short_code = v_promoter_code_raw
      AND pc.is_active = true
      AND pc.enterprise_root_id = v_shop_root
      AND pc.promoter_id <> v_uid;
    IF FOUND AND EXISTS (
      SELECT 1 FROM public.promoter_bindings b
      WHERE b.enterprise_root_id = v_shop_root
        AND b.promoter_id = v_promoter_id
        AND b.client_id = v_uid
    ) THEN
      SELECT * INTO v_rule FROM public.promotion_rules
      WHERE enterprise_root_id = v_shop_root;
      IF v_rule.id IS NOT NULL THEN
        IF v_rule.commission_mode = 'rate' THEN
          v_comm := (v_total * v_rule.commission_rate_bps) / 10000;
        ELSIF v_rule.commission_mode = 'fixed' THEN
          v_comm := LEAST(v_rule.commission_fixed_cents, v_total);
        END IF;
      END IF;
      IF v_comm <= 0 THEN
        v_promoter_id := NULL;
        v_promoter_code_raw := '';
      END IF;
    ELSE
      v_promoter_id := NULL;
      v_promoter_code_raw := '';
    END IF;
  ELSE
    v_promoter_id := NULL;
    v_promoter_code_raw := '';
  END IF;

  INSERT INTO orders (
    out_trade_no, user_id, product_id, sku_id,
    product_title_snapshot, cover_image_snapshot,
    unit_price_cents, quantity, total_amount_cents,
    product_source_type_snapshot, owner_manager_id_snapshot,
    shop_manager_id_snapshot,
    promoter_id_snapshot, promoter_code_snapshot, commission_cents_snapshot,
    status, preferred_payment_method,
    contact_name, contact_phone, shipping_province, shipping_city,
    shipping_district, shipping_address_detail, remark
  ) VALUES (
    v_otn, v_uid, v_product.id, v_sku.id,
    v_product.title, COALESCE(v_product.cover_image_url, ''),
    v_sku.price_cents, p_quantity, v_total,
    v_product.source_type, v_product.owner_manager_id,
    v_shop_root,
    v_promoter_id, v_promoter_code_raw, v_comm,
    'pending', p_preferred_payment_method,
    v_name, v_phone, v_prov, v_city,
    v_dist, v_addr, COALESCE(p_remark, '')
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

-- ───────────────────────────── 支付成功：同事务幂等入账佣金 ─────────────────────────────

CREATE OR REPLACE FUNCTION public.mark_order_paid_from_gateway(p_out_trade_no text, p_trade_no text, p_paid_amount integer, p_payment_method text)
RETURNS orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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

    -- 推广佣金入账：同事务幂等（线上现金单才有快照）
    IF v_order.promoter_id_snapshot IS NOT NULL AND v_order.commission_cents_snapshot > 0
       AND v_order.payment_channel = 'online' AND v_order.pay_mode = 'cash' THEN
      PERFORM public._post_commission_delta(
        v_order.promoter_id_snapshot,
        v_order.commission_cents_snapshot,
        0,
        'commission',
        'order',
        v_order.id,
        'commission:paid:' || v_order.id::text
      );

      UPDATE public.promoter_bindings
      SET order_count = order_count + 1,
          total_commission_cents = total_commission_cents + v_order.commission_cents_snapshot
      WHERE enterprise_root_id = v_order.shop_manager_id_snapshot
        AND promoter_id = v_order.promoter_id_snapshot
        AND client_id = v_order.user_id;
    END IF;

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
$function$;

-- ───────────────────────────── 全额退款：同事务冲销佣金 ─────────────────────────────

CREATE OR REPLACE FUNCTION public.mark_order_refunded_from_gateway(p_out_trade_no text, p_refund_amount integer, p_reason text)
RETURNS orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
        refund_reason = COALESCE(p_reason, ''),
        manual_refund_required = false
    WHERE id = v_order.id
    RETURNING * INTO v_order;

  -- 佣金冲销：只在「曾入账成功」的前提下冲（幂等键防回调重试重复冲销）
  IF v_order.promoter_id_snapshot IS NOT NULL AND v_order.commission_cents_snapshot > 0
     AND EXISTS (
       SELECT 1 FROM public.commission_ledger l
       WHERE l.idempotency_key = 'commission:paid:' || v_order.id::text
     ) THEN
    PERFORM public._post_commission_delta(
      v_order.promoter_id_snapshot,
      -v_order.commission_cents_snapshot,
      0,
      'reversal',
      'order',
      v_order.id,
      'commission:refund:' || v_order.id::text
    );

    UPDATE public.promoter_bindings
    SET total_commission_cents = GREATEST(total_commission_cents - v_order.commission_cents_snapshot, 0)
    WHERE enterprise_root_id = v_order.shop_manager_id_snapshot
      AND promoter_id = v_order.promoter_id_snapshot
      AND client_id = v_order.user_id;
  END IF;

  RETURN v_order;
END;
$function$;

-- ───────────────────────────── 商户推广总览：变量赋值修正 ─────────────────────────────

CREATE OR REPLACE FUNCTION public.get_merchant_promotion_overview()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_root uuid := public._my_root_manager_id();
  v_rule public.promotion_rules;
  v_promoters jsonb;
  v_total_comm bigint;
  v_pending bigint;
BEGIN
  IF v_uid IS NULL OR NOT public.has_enterprise_permission('marketing_center', v_uid) THEN
    RAISE EXCEPTION '没有营销中心权限' USING ERRCODE = '42501';
  END IF;
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_rule FROM public.promotion_rules WHERE enterprise_root_id = v_root;

  SELECT COALESCE(jsonb_agg(prom), '[]'::jsonb) INTO v_promoters
  FROM (
    SELECT pc.promoter_id,
           COALESCE(pr.display_name, '') AS name,
           pr.role,
           pc.short_code,
           pc.is_active,
           pc.created_at,
           (SELECT COUNT(*) FROM public.promoter_bindings b
             WHERE b.enterprise_root_id = pc.enterprise_root_id AND b.promoter_id = pc.promoter_id) AS bound_count,
           (SELECT COALESCE(SUM(b.order_count), 0) FROM public.promoter_bindings b
             WHERE b.enterprise_root_id = pc.enterprise_root_id AND b.promoter_id = pc.promoter_id) AS order_count,
           (SELECT COALESCE(SUM(b.total_commission_cents), 0) FROM public.promoter_bindings b
             WHERE b.enterprise_root_id = pc.enterprise_root_id AND b.promoter_id = pc.promoter_id) AS total_commission_cents,
           (SELECT COALESCE(SUM(c.balance_cents), 0) FROM public.commission_accounts c
             WHERE c.profile_id = pc.promoter_id) AS balance_cents
    FROM public.promotion_codes pc
    LEFT JOIN public.profiles pr ON pr.id = pc.promoter_id
    WHERE pc.enterprise_root_id = v_root
    ORDER BY pc.created_at DESC
  ) prom;

  SELECT COALESCE(SUM(b.total_commission_cents), 0)
  INTO v_total_comm
  FROM public.promoter_bindings b
  WHERE b.enterprise_root_id = v_root;

  SELECT COUNT(*) INTO v_pending
  FROM public.withdrawal_requests w
  WHERE w.enterprise_root_id = v_root AND w.status = 'pending';

  RETURN jsonb_build_object(
    'rule', CASE WHEN v_rule.id IS NULL THEN NULL ELSE jsonb_build_object(
      'inviter_points', v_rule.inviter_points,
      'invitee_points', v_rule.invitee_points,
      'commission_mode', v_rule.commission_mode,
      'commission_rate_bps', v_rule.commission_rate_bps,
      'commission_fixed_cents', v_rule.commission_fixed_cents
    ) END,
    'promoters', v_promoters,
    'total_commission_cents', COALESCE(v_total_comm, 0),
    'pending_withdrawal_count', COALESCE(v_pending, 0)
  );
END;
$function$;