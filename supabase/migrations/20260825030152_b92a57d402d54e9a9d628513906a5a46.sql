-- ───────────────────────────── 下单：接收推广码并固化佣金快照 ─────────────────────────────

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
        IF v_rule.commission_mode = 'rate' AND v_rule.commission_rate_bps > 0 THEN
          -- 金额先乘后除再向下取整，避免中间浮点
          v_comm := (v_sku_price_total() * v_rule.commission_rate_bps) / 10000;
        ELSIF v_rule.commission_mode = 'fixed' AND v_rule.commission_fixed_cents > 0 THEN
          v_comm := LEAST(v_rule.commission_fixed_cents, v_total_provisional());
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

  -- 佣金重算：上面预估依赖价格，这里用确定价格重算一次（比例模式）
  IF v_promoter_id IS NOT NULL AND v_rule.id IS NOT NULL AND v_rule.commission_mode = 'rate' THEN
    v_comm := (v_total * v_rule.commission_rate_bps) / 10000;
    IF v_comm <= 0 THEN
      v_promoter_id := NULL;
      v_promoter_code_raw := '';
    END IF;
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

-- 下单佣金预估辅助（create_shop_order 内部使用）
CREATE OR REPLACE FUNCTION public._order_total_provisional()
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT 0;
$function$;

REVOKE EXECUTE ON FUNCTION public._order_total_provisional() FROM PUBLIC, anon, authenticated;