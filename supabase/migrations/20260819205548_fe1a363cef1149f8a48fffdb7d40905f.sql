-- 商城按店彻底隔离（Feature 196）
-- 1. get_storefront_products：店面商品只按「当前店」取数，游客可浏览，不再依赖用户绑定/分享授权
-- 2. get_storefront_module_state：积分专区开关按当前店解析
-- 3. _can_order_product_in_shop：去掉 can_view_product 授权前置，直接按店校验
-- 4. 三个下单函数：前端传的店只作「在哪买」的上下文，订单归属以商品实际归属为准
-- 5. client_relations 部分索引（平台端所属商户 UNION 查询用）

-- ── 1. 店面商品查询 ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_storefront_products(
  p_shop_root uuid DEFAULT NULL,
  p_sale_mode text DEFAULT NULL,
  p_limit integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
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
      SELECT to_jsonb(p) || jsonb_build_object(
        'product_skus',
        COALESCE((SELECT jsonb_agg(to_jsonb(s)) FROM public.product_skus s WHERE s.product_id = p.id), '[]'::jsonb)
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

  -- 积分专区：该店积分兑换模块必须平台授予且商户开启
  IF v_mode = 'points' AND NOT EXISTS (
    SELECT 1 FROM public.merchant_module_grants g
    WHERE g.manager_id = v_root
      AND g.module_key = 'points_exchange'
      AND g.grant_status = 'granted'
      AND g.is_enabled = TRUE
  ) THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(t.row_json), '[]'::jsonb) INTO v_out
  FROM (
    SELECT to_jsonb(p) || jsonb_build_object(
      'product_skus',
      COALESCE((SELECT jsonb_agg(to_jsonb(s)) FROM public.product_skus s WHERE s.product_id = p.id), '[]'::jsonb)
    ) AS row_json
    FROM public.products p
    WHERE p.source_type = 'manager'
      AND p.status = 'active'
      AND p.owner_manager_id IS NOT NULL
      AND public.get_enterprise_root_manager_id(p.owner_manager_id) = v_root
      AND (v_mode IS NULL OR COALESCE(p.sale_mode, 'cash') = v_mode)
      AND (p.virtual_card_code IS NULL OR p.virtual_card_code = 'consumer_health365')
    ORDER BY p.is_featured DESC, p.sort_weight DESC, p.created_at DESC
    LIMIT v_limit
  ) t;

  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_storefront_products(uuid, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_storefront_products(uuid, text, integer) TO anon, authenticated;

-- ── 2. 店面模块开关（按当前店解析，游客可查） ──────────────────
CREATE OR REPLACE FUNCTION public.get_storefront_module_state(
  p_shop_root uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root   uuid;
  v_points boolean := false;
BEGIN
  -- 平台主店：平台自营积分商品不依赖商户授权，专区常开
  IF p_shop_root IS NULL THEN
    RETURN jsonb_build_object('pointsExchange', true);
  END IF;

  v_root := public.get_enterprise_root_manager_id(p_shop_root);
  IF v_root IS NOT NULL AND public.is_public_enterprise_content_root(v_root) THEN
    v_points := EXISTS (
      SELECT 1 FROM public.merchant_module_grants g
      WHERE g.manager_id = v_root
        AND g.module_key = 'points_exchange'
        AND g.grant_status = 'granted'
        AND g.is_enabled = TRUE
    );
  END IF;
  RETURN jsonb_build_object('pointsExchange', v_points);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_storefront_module_state(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_storefront_module_state(uuid) TO anon, authenticated;

-- ── 3. 下单可购校验：不再依赖 can_view_product 的授权表 ────────
CREATE OR REPLACE FUNCTION public._can_order_product_in_shop(
  p_product_id uuid,
  p_user_id uuid,
  p_shop_root uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_product public.products;
  v_product_root uuid;
BEGIN
  SELECT * INTO v_product FROM public.products WHERE id = p_product_id;
  IF v_product.id IS NULL OR v_product.status <> 'active' THEN
    RETURN false;
  END IF;

  -- 平台商品只在平台主店（无 shop 上下文）可买；商户店内不可下单
  IF v_product.source_type = 'platform' THEN
    RETURN p_shop_root IS NULL;
  END IF;

  -- 商户商品：归属店必须等于当前店，且该店已认证未禁用
  IF v_product.owner_manager_id IS NULL THEN
    RETURN false;
  END IF;
  v_product_root := public.get_enterprise_root_manager_id(v_product.owner_manager_id);
  IF v_product_root IS NULL OR p_shop_root IS NULL OR v_product_root <> p_shop_root THEN
    RETURN false;
  END IF;
  IF NOT public.is_public_enterprise_content_root(v_product_root) THEN
    RETURN false;
  END IF;

  -- 积分商品：该店积分兑换模块开放，且下单人是本店客户（正式关系或进店会员）
  IF COALESCE(v_product.sale_mode, 'cash') = 'points' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.merchant_module_grants g
      WHERE g.manager_id = v_product_root
        AND g.module_key = 'points_exchange'
        AND g.grant_status = 'granted'
        AND g.is_enabled = TRUE
    ) THEN
      RETURN false;
    END IF;
    RETURN EXISTS (
      SELECT 1 FROM public.client_relations cr
      WHERE cr.client_id = p_user_id
        AND cr.status = 'active'
        AND public.get_enterprise_root_manager_id(cr.manager_id) = v_product_root
    ) OR EXISTS (
      SELECT 1 FROM public.shop_members sm
      WHERE sm.client_id = p_user_id
        AND sm.root_manager_id = v_product_root
    );
  END IF;

  RETURN true;
END;
$function$;

-- ── 4a. create_shop_order：上下文与归属分离 ────────────────────
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
  p_remark                    TEXT DEFAULT '',
  p_shop_manager_id           UUID DEFAULT NULL
) RETURNS orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

  INSERT INTO orders (
    out_trade_no, user_id, product_id, sku_id,
    product_title_snapshot, cover_image_snapshot,
    unit_price_cents, quantity, total_amount_cents,
    product_source_type_snapshot, owner_manager_id_snapshot,
    shop_manager_id_snapshot,
    status, preferred_payment_method,
    contact_name, contact_phone, shipping_province, shipping_city,
    shipping_district, shipping_address_detail, remark
  ) VALUES (
    v_otn, v_uid, v_product.id, v_sku.id,
    v_product.title, COALESCE(v_product.cover_image_url, ''),
    v_sku.price_cents, p_quantity, v_total,
    v_product.source_type, v_product.owner_manager_id,
    v_shop_root,
    'pending', p_preferred_payment_method,
    v_name, v_phone, v_prov, v_city,
    v_dist, v_addr, COALESCE(p_remark, '')
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_shop_order(text, uuid, integer, text, text, text, text, text, text, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_shop_order(text, uuid, integer, text, text, text, text, text, text, text, text, uuid) TO authenticated;

-- ── 4b. create_points_order：上下文与归属分离 ───────────────────
CREATE OR REPLACE FUNCTION public.create_points_order(
  p_out_trade_no text,
  p_product_id uuid,
  p_quantity integer,
  p_address_id uuid DEFAULT NULL::uuid,
  p_remark text DEFAULT ''::text,
  p_shop_manager_id uuid DEFAULT NULL::uuid
)
RETURNS orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid     uuid := auth.uid();
  v_otn     text;
  v_product public.products;
  v_sku     public.product_skus;
  v_addr    public.user_shipping_addresses;
  v_balance integer;
  v_cost    integer;
  v_row     public.orders;
  v_shop_root uuid;
  v_context_root uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = v_uid AND role = 'user' AND is_disabled = false
  ) THEN
    RAISE EXCEPTION '只有用户端账号可以兑换商品' USING ERRCODE = '42501';
  END IF;

  v_otn := btrim(COALESCE(p_out_trade_no, ''));
  IF v_otn = '' OR char_length(v_otn) > 64 THEN
    RAISE EXCEPTION '兑换单号不合法' USING ERRCODE = '22023';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 999 THEN
    RAISE EXCEPTION '兑换数量必须在 1 到 999 之间' USING ERRCODE = '22023';
  END IF;
  IF char_length(COALESCE(p_remark, '')) > 200 THEN
    RAISE EXCEPTION '备注最多 200 字' USING ERRCODE = '22023';
  END IF;

  -- 下单上下文：前端报的「当前所在店」只作在哪兑换的校验，订单归属以商品为准
  v_context_root := public._resolve_order_shop_root(p_shop_manager_id);

  SELECT * INTO v_product FROM public.products WHERE id = p_product_id;
  IF v_product.id IS NULL THEN
    RAISE EXCEPTION '商品不存在' USING ERRCODE = '22023';
  END IF;
  IF v_product.status <> 'active' THEN
    RAISE EXCEPTION '该商品已下架' USING ERRCODE = '22023';
  END IF;
  IF v_product.sale_mode IS DISTINCT FROM 'points' THEN
    RAISE EXCEPTION '该商品不支持积分兑换' USING ERRCODE = '22023';
  END IF;

  -- 可购校验：含积分模块开放与本店客户（正式关系或进店会员）资格
  IF NOT public._can_order_product_in_shop(p_product_id, v_uid, v_context_root) THEN
    RAISE EXCEPTION '这件商品当前不向你开放兑换' USING ERRCODE = '42501';
  END IF;

  -- 订单归属以商品实际归属为准：商户商品→其企业根；平台商品→平台主店（NULL）
  IF v_product.source_type = 'manager' THEN
    v_shop_root := public.get_enterprise_root_manager_id(v_product.owner_manager_id);
  ELSE
    v_shop_root := NULL;
  END IF;

  SELECT * INTO v_sku
  FROM public.product_skus
  WHERE product_id = p_product_id AND is_default = true
  LIMIT 1
  FOR UPDATE;

  IF v_sku.id IS NULL THEN
    RAISE EXCEPTION '商品规格不存在' USING ERRCODE = '22023';
  END IF;
  IF v_sku.is_active = false THEN
    RAISE EXCEPTION '该商品规格已停用' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(v_sku.points_price, 0) <= 0 THEN
    RAISE EXCEPTION '该商品尚未设置积分价' USING ERRCODE = '22023';
  END IF;
  IF v_sku.stock < p_quantity THEN
    RAISE EXCEPTION '库存不足，当前仅剩 % 件', v_sku.stock USING ERRCODE = '22023';
  END IF;

  v_cost := v_sku.points_price * p_quantity;

  IF v_product.requires_shipping = true THEN
    IF p_address_id IS NULL THEN
      RAISE EXCEPTION '请先选择收货地址' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_addr
    FROM public.user_shipping_addresses
    WHERE id = p_address_id AND user_id = v_uid;
    IF v_addr.id IS NULL THEN
      RAISE EXCEPTION '收货地址不存在' USING ERRCODE = '22023';
    END IF;
  END IF;

  INSERT INTO public.points_balances (user_id) VALUES (v_uid)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT b.balance INTO v_balance
  FROM public.points_balances b
  WHERE b.user_id = v_uid
  FOR UPDATE;

  IF COALESCE(v_balance, 0) < v_cost THEN
    RAISE EXCEPTION '积分不足，本次需要 % 分，当前可用 % 分', v_cost, COALESCE(v_balance, 0)
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.orders (
    out_trade_no, user_id, product_id, sku_id,
    product_title_snapshot, cover_image_snapshot,
    unit_price_cents, quantity, total_amount_cents, paid_amount_cents,
    pay_mode, unit_points, points_amount,
    product_source_type_snapshot, owner_manager_id_snapshot,
    shop_manager_id_snapshot,
    status, paid_at, stock_decremented, preferred_payment_method,
    contact_name, contact_phone, shipping_province, shipping_city,
    shipping_district, shipping_address_detail, remark,
    requires_shipping_snapshot
  ) VALUES (
    v_otn, v_uid, v_product.id, v_sku.id,
    v_product.title, COALESCE(v_product.cover_image_url, ''),
    0, p_quantity, 0, 0,
    'points', v_sku.points_price, v_cost,
    v_product.source_type, v_product.owner_manager_id,
    v_shop_root,
    'paid', now(), true, NULL,
    COALESCE(v_addr.contact_name, ''), COALESCE(v_addr.contact_phone, ''),
    COALESCE(v_addr.province, ''), COALESCE(v_addr.city, ''),
    COALESCE(v_addr.district, ''), COALESCE(v_addr.address_detail, ''),
    COALESCE(p_remark, ''),
    COALESCE(v_product.requires_shipping, true)
  )
  RETURNING * INTO v_row;

  UPDATE public.product_skus
  SET stock = stock - p_quantity,
      updated_at = now()
  WHERE id = v_sku.id;

  UPDATE public.points_balances
  SET balance = balance - v_cost,
      updated_at = now()
  WHERE user_id = v_uid;

  RETURN v_row;
END;
$function$;

-- ── 4c. create_virtual_card_order：上下文与归属分离 ─────────────
CREATE OR REPLACE FUNCTION public.create_virtual_card_order(
  p_out_trade_no text,
  p_product_id uuid,
  p_preferred_payment_method text,
  p_referrer_manager_id uuid DEFAULT NULL::uuid,
  p_referrer_invite_code text DEFAULT NULL::text,
  p_shop_manager_id uuid DEFAULT NULL::uuid
)
RETURNS orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_profile public.profiles;
  v_product public.products;
  v_sku public.product_skus;
  v_row public.orders;
  v_otn text;
  v_referrer_id uuid;
  v_target_role text;
  v_shop_root uuid;
  v_context_root uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden: not authenticated';
  END IF;

  SELECT * INTO v_profile FROM profiles WHERE id = v_uid AND is_disabled = false;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'forbidden: account not found or disabled';
  END IF;
  IF v_profile.role NOT IN ('user','manager') THEN
    RAISE EXCEPTION 'forbidden: only consumer or manager accounts can purchase cards';
  END IF;

  v_otn := btrim(COALESCE(p_out_trade_no, ''));
  IF v_otn = '' OR char_length(v_otn) > 64 THEN
    RAISE EXCEPTION 'invalid out_trade_no';
  END IF;
  IF p_preferred_payment_method NOT IN ('wechat','alipay') THEN
    RAISE EXCEPTION 'preferred_payment_method must be wechat or alipay';
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
  IF v_product.requires_shipping THEN
    RAISE EXCEPTION 'this product requires shipping, use create_shop_order instead';
  END IF;
  IF v_product.virtual_card_code IS NULL THEN
    RAISE EXCEPTION 'product is not configured as a virtual card';
  END IF;

  v_target_role := CASE
    WHEN v_product.virtual_card_code = 'consumer_health365' THEN 'user'
    WHEN v_product.virtual_card_code IN ('manager_basic_365', 'manager_advanced_pack') THEN 'manager'
    ELSE NULL
  END;
  IF v_target_role IS NULL OR v_target_role <> v_profile.role::text THEN
    RAISE EXCEPTION 'this card is not available for your account type';
  END IF;

  IF v_profile.role = 'manager' THEN
    IF v_profile.parent_manager_id IS NOT NULL THEN
      RAISE EXCEPTION 'forbidden: enterprise staff accounts inherit membership from the owner and cannot purchase directly';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM managers WHERE id = v_uid) THEN
      RAISE EXCEPTION 'manager record not found';
    END IF;
  END IF;

  -- 可购校验：虚拟卡虽是平台商品，商户私域场景下仍要走同一道闸保持一致
  IF NOT public._can_order_product_in_shop(p_product_id, v_uid, v_context_root) THEN
    RAISE EXCEPTION 'this card is not available in this shop';
  END IF;

  -- 订单归属以商品实际归属为准：商户商品→其企业根；平台商品→平台主店（NULL）
  IF v_product.source_type = 'manager' THEN
    v_shop_root := public.get_enterprise_root_manager_id(v_product.owner_manager_id);
  ELSE
    v_shop_root := NULL;
  END IF;

  SELECT * INTO v_sku FROM product_skus WHERE product_id = p_product_id AND is_default = true LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'default sku not found';
  END IF;
  IF v_sku.is_active = false THEN
    RAISE EXCEPTION 'sku not active';
  END IF;
  IF v_sku.price_cents <= 0 THEN
    RAISE EXCEPTION 'product price not configured';
  END IF;

  IF p_referrer_invite_code IS NOT NULL AND btrim(p_referrer_invite_code) <> '' THEN
    SELECT id INTO v_referrer_id FROM managers WHERE invite_code = btrim(p_referrer_invite_code);
  END IF;
  IF v_referrer_id IS NULL AND p_referrer_manager_id IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM managers WHERE id = p_referrer_manager_id) THEN
      v_referrer_id := p_referrer_manager_id;
    END IF;
  END IF;
  IF v_referrer_id IS NULL AND v_profile.role = 'user' THEN
    SELECT manager_id INTO v_referrer_id
    FROM client_relations
    WHERE client_id = v_uid AND status = 'active'
    LIMIT 1;
  END IF;

  INSERT INTO orders (
    out_trade_no, user_id, product_id, sku_id,
    product_title_snapshot, cover_image_snapshot,
    unit_price_cents, quantity, total_amount_cents,
    product_source_type_snapshot, owner_manager_id_snapshot,
    shop_manager_id_snapshot,
    status, preferred_payment_method,
    contact_name, contact_phone, shipping_province, shipping_city,
    shipping_district, shipping_address_detail, remark,
    requires_shipping_snapshot, virtual_card_code_snapshot
  ) VALUES (
    v_otn, v_uid, v_product.id, v_sku.id,
    v_product.title, COALESCE(v_product.cover_image_url, ''),
    v_sku.price_cents, 1, v_sku.price_cents,
    v_product.source_type, v_product.owner_manager_id,
    v_shop_root,
    'pending', p_preferred_payment_method,
    COALESCE(NULLIF(v_profile.nickname, ''), '虚拟权益购买'), COALESCE(v_profile.phone, ''), '', '',
    '', '', '虚拟权益商品，无需发货',
    false, v_product.virtual_card_code
  )
  RETURNING * INTO v_row;

  INSERT INTO virtual_card_purchases (
    order_id, out_trade_no, buyer_id, buyer_role, product_id, sku_id,
    virtual_card_code, target_manager_id, target_plan_code,
    referrer_manager_id, referrer_invite_code, attribution_source, grant_status
  ) VALUES (
    v_row.id, v_otn, v_uid, v_profile.role::text, v_product.id, v_sku.id,
    v_product.virtual_card_code,
    CASE WHEN v_profile.role = 'manager' THEN v_uid ELSE NULL END,
    CASE
      WHEN v_product.virtual_card_code = 'manager_basic_365' THEN 'basic'
      WHEN v_product.virtual_card_code = 'manager_advanced_pack' THEN 'advanced'
      ELSE NULL
    END,
    v_referrer_id,
    NULLIF(btrim(COALESCE(p_referrer_invite_code, '')), ''),
    CASE WHEN v_referrer_id IS NULL THEN 'platform' ELSE 'referrer' END,
    'pending'
  );

  RETURN v_row;
END;
$function$;

-- ── 5. 平台端所属商户 UNION 查询的部分索引 ─────────────────────
CREATE INDEX IF NOT EXISTS client_relations_active_client_manager_idx
  ON public.client_relations (client_id, manager_id)
  WHERE status = 'active';