CREATE OR REPLACE FUNCTION public.create_virtual_card_order(
  p_out_trade_no text,
  p_product_id uuid,
  p_preferred_payment_method text,
  p_referrer_manager_id uuid DEFAULT NULL,
  p_referrer_invite_code text DEFAULT NULL
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
    status, preferred_payment_method,
    contact_name, contact_phone, shipping_province, shipping_city,
    shipping_district, shipping_address_detail, remark,
    requires_shipping_snapshot, virtual_card_code_snapshot
  ) VALUES (
    v_otn, v_uid, v_product.id, v_sku.id,
    v_product.title, COALESCE(v_product.cover_image_url, ''),
    v_sku.price_cents, 1, v_sku.price_cents,
    v_product.source_type, v_product.owner_manager_id,
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
    CASE
      WHEN p_referrer_invite_code IS NOT NULL AND btrim(p_referrer_invite_code) <> '' THEN 'invite_code'
      WHEN p_referrer_manager_id IS NOT NULL THEN 'manager_id'
      WHEN v_referrer_id IS NOT NULL THEN 'bound_manager'
      ELSE 'none'
    END,
    'pending'
  );

  RETURN v_row;
END;
$function$;