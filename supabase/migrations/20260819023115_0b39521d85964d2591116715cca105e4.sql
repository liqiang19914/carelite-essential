-- 订单按下单商城归属（feature 189）
-- 订单新增「下单商城」快照：客户下单时所在商城的企业根。
-- 与「商品归属」owner_manager_id_snapshot 是两个独立概念：
--   平台严选商品在某商户店里卖出 → shop=该商户根、owner=NULL、履约仍归平台。
-- 商城归属只控制可见性与销售归因，不改变发货/退款责任。

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS shop_manager_id_snapshot uuid NULL;

COMMENT ON COLUMN public.orders.shop_manager_id_snapshot IS
  '下单时所在商城的企业根管理师 ID 快照；NULL 表示平台主端下单或历史商城归属无法确定';

CREATE INDEX IF NOT EXISTS idx_orders_shop_created
  ON public.orders (shop_manager_id_snapshot, created_at DESC, id DESC)
  WHERE shop_manager_id_snapshot IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_orders_shop_status_created
  ON public.orders (shop_manager_id_snapshot, status, created_at DESC, id DESC)
  WHERE shop_manager_id_snapshot IS NOT NULL;

-- 解析并校验下单商城：NULL=平台主端；否则必须是公开内容根（员工 ID 也归一到企业根）
CREATE OR REPLACE FUNCTION public._resolve_order_shop_root(p_shop_manager_id uuid)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
BEGIN
  IF p_shop_manager_id IS NULL THEN
    RETURN NULL;
  END IF;
  v_root := public.get_enterprise_root_manager_id(p_shop_manager_id);
  IF v_root IS NULL OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RAISE EXCEPTION '商城当前不可用' USING ERRCODE = '42501';
  END IF;
  RETURN v_root;
END;
$function$;

-- 商城上下文内的可购校验：在「能看见商品」之上叠加「商品允许在当前商城出售」。
-- 严格跨店规则：A 店可买平台严选与 A 店自营；平台主端（shop 为空）不可买商户私域商品。
CREATE OR REPLACE FUNCTION public._can_order_product_in_shop(
  p_product_id uuid,
  p_user_id uuid,
  p_shop_root uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_product public.products;
  v_product_root uuid;
BEGIN
  IF NOT public.can_view_product(p_product_id, p_user_id) THEN
    RETURN false;
  END IF;
  SELECT * INTO v_product FROM public.products WHERE id = p_product_id;
  IF v_product.id IS NULL THEN
    RETURN false;
  END IF;
  IF v_product.source_type = 'platform' THEN
    RETURN true;
  END IF;
  v_product_root := public.get_enterprise_root_manager_id(v_product.owner_manager_id);
  IF p_shop_root IS NULL THEN
    RETURN false;
  END IF;
  RETURN v_product_root IS NOT NULL AND v_product_root = p_shop_root;
END;
$function$;

-- ── create_shop_order：加 p_shop_manager_id（DROP 旧重载避免 PostgREST 歧义）──
DROP FUNCTION IF EXISTS public.create_shop_order(text, uuid, integer, text, text, text, text, text, text, text, text);
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
  v_shop_root UUID;
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

  -- 下单商城：必须在商品校验之前解析，后面的可购校验要用
  v_shop_root := public._resolve_order_shop_root(p_shop_manager_id);

  SELECT * INTO v_product FROM products WHERE id = p_product_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'product not found';
  END IF;
  IF v_product.status <> 'active' THEN
    RAISE EXCEPTION 'product not active';
  END IF;

  -- 商城上下文内可购：防止在 A 店拿 B 店私域商品 UUID 下单、或在平台主端买商户私域商品
  IF NOT public._can_order_product_in_shop(p_product_id, v_uid, v_shop_root) THEN
    RAISE EXCEPTION '这件商品当前不向你开放购买';
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
$$;

REVOKE ALL ON FUNCTION public.create_shop_order(text, uuid, integer, text, text, text, text, text, text, text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_shop_order(text, uuid, integer, text, text, text, text, text, text, text, text, uuid) TO authenticated;

-- ── create_points_order：加 p_shop_manager_id ──
DROP FUNCTION IF EXISTS public.create_points_order(text, uuid, integer, uuid, text);
CREATE OR REPLACE FUNCTION public.create_points_order(
  p_out_trade_no text,
  p_product_id uuid,
  p_quantity integer,
  p_address_id uuid DEFAULT NULL::uuid,
  p_remark text DEFAULT ''::text,
  p_shop_manager_id uuid DEFAULT NULL
)
RETURNS orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
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

  v_shop_root := public._resolve_order_shop_root(p_shop_manager_id);

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

  -- 商城上下文内可购（含原「本企业活跃客户 + 模块开放」的 can_view_product 闸门）
  IF NOT public._can_order_product_in_shop(p_product_id, v_uid, v_shop_root) THEN
    RAISE EXCEPTION '这件商品当前不向你开放兑换' USING ERRCODE = '42501';
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

REVOKE ALL ON FUNCTION public.create_points_order(text, uuid, integer, uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_points_order(text, uuid, integer, uuid, text, uuid) TO authenticated;

-- ── create_virtual_card_order：加 p_shop_manager_id ──
DROP FUNCTION IF EXISTS public.create_virtual_card_order(text, uuid, text, uuid, text);
CREATE OR REPLACE FUNCTION public.create_virtual_card_order(
  p_out_trade_no text,
  p_product_id uuid,
  p_preferred_payment_method text,
  p_referrer_manager_id uuid DEFAULT NULL,
  p_referrer_invite_code text DEFAULT NULL,
  p_shop_manager_id uuid DEFAULT NULL
) RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
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

  v_shop_root := public._resolve_order_shop_root(p_shop_manager_id);

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

  -- 商城上下文内可购：虚拟卡虽是平台商品，商户私域场景下仍要走同一道闸保持一致
  IF NOT public._can_order_product_in_shop(p_product_id, v_uid, v_shop_root) THEN
    RAISE EXCEPTION 'this card is not available in this shop';
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

REVOKE ALL ON FUNCTION public.create_virtual_card_order(text, uuid, text, uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_virtual_card_order(text, uuid, text, uuid, text, uuid) TO authenticated;