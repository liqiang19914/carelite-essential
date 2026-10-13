-- 1. products: 虚拟卡商品支持
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS requires_shipping boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS virtual_card_code text NULL;

-- 2. orders: 快照字段
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS requires_shipping_snapshot boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS virtual_card_code_snapshot text NULL;

-- 3. profiles: 消费者会员标记
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS health365_member_expires_at timestamptz NULL;

-- 4. 虚拟卡购买流水表（幂等账本 + 归属留存）
CREATE TABLE public.virtual_card_purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL UNIQUE REFERENCES public.orders(id) ON DELETE CASCADE,
  out_trade_no text NOT NULL UNIQUE,
  buyer_id uuid NOT NULL REFERENCES public.profiles(id),
  buyer_role text NOT NULL,
  product_id uuid NULL REFERENCES public.products(id),
  sku_id uuid NULL,
  virtual_card_code text NOT NULL,
  target_manager_id uuid NULL,
  target_plan_code text NULL,
  referrer_manager_id uuid NULL,
  referrer_invite_code text NULL,
  attribution_source text NULL,
  grant_status text NOT NULL DEFAULT 'pending' CHECK (grant_status IN ('pending','applied','deferred','noop','failed')),
  grant_reason text NULL,
  expires_at timestamptz NULL,
  applied_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX idx_virtual_card_purchases_buyer ON public.virtual_card_purchases(buyer_id);
CREATE INDEX idx_virtual_card_purchases_target_manager ON public.virtual_card_purchases(target_manager_id) WHERE target_manager_id IS NOT NULL;
CREATE INDEX idx_virtual_card_purchases_deferred ON public.virtual_card_purchases(grant_status) WHERE grant_status = 'deferred';

ALTER TABLE public.virtual_card_purchases ENABLE ROW LEVEL SECURITY;

CREATE POLICY "buyer can view own purchase" ON public.virtual_card_purchases
  FOR SELECT USING (buyer_id = auth.uid());

CREATE POLICY "admin can view all purchases" ON public.virtual_card_purchases
  FOR SELECT USING (public.is_admin(auth.uid()));

-- 5. 虚拟卡下单 RPC（独立于 create_shop_order，不改动实体商品下单路径）
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
  IF v_target_role IS NULL OR v_target_role <> v_profile.role THEN
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
    v_row.id, v_otn, v_uid, v_profile.role, v_product.id, v_sku.id,
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

-- 6. 权益发放 RPC（支付成功回调后调用，幂等）
CREATE OR REPLACE FUNCTION public.grant_virtual_card_entitlement(
  p_out_trade_no text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_order public.orders;
  v_purchase public.virtual_card_purchases;
  v_manager public.managers;
  v_expires timestamptz;
  v_target_limit integer;
  v_current_sort integer;
  v_target_sort integer;
BEGIN
  SELECT * INTO v_order FROM orders WHERE out_trade_no = p_out_trade_no FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'order_not_found');
  END IF;
  IF v_order.status <> 'paid' THEN
    RETURN jsonb_build_object('status', 'ignored', 'reason', 'order_not_paid', 'order_status', v_order.status);
  END IF;
  IF v_order.virtual_card_code_snapshot IS NULL THEN
    RETURN jsonb_build_object('status', 'ignored', 'reason', 'not_a_virtual_card_order');
  END IF;

  SELECT * INTO v_purchase FROM virtual_card_purchases WHERE order_id = v_order.id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'ignored', 'reason', 'purchase_record_missing');
  END IF;

  IF v_purchase.grant_status IN ('applied', 'noop', 'deferred') THEN
    RETURN jsonb_build_object('status', 'already_processed', 'grant_status', v_purchase.grant_status);
  END IF;

  v_expires := now() + interval '1 year';

  IF v_purchase.virtual_card_code = 'consumer_health365' THEN
    UPDATE profiles
    SET health365_member_expires_at = v_expires
    WHERE id = v_purchase.buyer_id;

    UPDATE virtual_card_purchases
    SET grant_status = 'applied', expires_at = v_expires, applied_at = now(), updated_at = now()
    WHERE id = v_purchase.id;

    RETURN jsonb_build_object('status', 'applied', 'card', 'consumer_health365');
  END IF;

  IF v_purchase.virtual_card_code IN ('manager_basic_365', 'manager_advanced_pack') THEN
    SELECT m.* INTO v_manager FROM managers m WHERE m.id = v_purchase.target_manager_id FOR UPDATE;
    IF NOT FOUND THEN
      UPDATE virtual_card_purchases
      SET grant_status = 'failed', grant_reason = 'manager_record_missing', updated_at = now()
      WHERE id = v_purchase.id;
      RETURN jsonb_build_object('status', 'failed', 'reason', 'manager_record_missing');
    END IF;

    IF v_manager.certification_status <> 'approved' THEN
      UPDATE virtual_card_purchases
      SET grant_status = 'deferred', expires_at = v_expires, updated_at = now()
      WHERE id = v_purchase.id;
      RETURN jsonb_build_object('status', 'deferred', 'reason', 'manager_not_approved');
    END IF;

    SELECT sort_order INTO v_current_sort FROM membership_plans WHERE code = v_manager.membership_level;
    SELECT sort_order INTO v_target_sort FROM membership_plans WHERE code = v_purchase.target_plan_code;

    IF v_current_sort IS NOT NULL AND v_target_sort IS NOT NULL AND v_current_sort >= v_target_sort THEN
      UPDATE virtual_card_purchases
      SET grant_status = 'noop', grant_reason = 'already_at_or_above_target_plan', expires_at = v_expires, applied_at = now(), updated_at = now()
      WHERE id = v_purchase.id;
      RETURN jsonb_build_object('status', 'noop', 'reason', 'already_at_or_above_target_plan');
    END IF;

    v_target_limit := CASE WHEN v_purchase.target_plan_code = 'basic' THEN 20 ELSE NULL END;

    UPDATE managers
    SET membership_level = v_purchase.target_plan_code,
        membership_enforcement_mode = 'enforced',
        client_limit_override = v_target_limit,
        membership_expires_at = v_expires,
        membership_updated_at = now(),
        membership_note = CASE
          WHEN v_purchase.target_plan_code = 'basic' THEN '在线购买365管理师开通卡：升级基础版，客户名额覆盖为20'
          ELSE '在线购买高级管理师包：升级高级版'
        END
    WHERE id = v_manager.id;

    UPDATE virtual_card_purchases
    SET grant_status = 'applied', expires_at = v_expires, applied_at = now(), updated_at = now()
    WHERE id = v_purchase.id;

    RETURN jsonb_build_object('status', 'applied', 'card', v_purchase.virtual_card_code, 'plan_code', v_purchase.target_plan_code);
  END IF;

  RETURN jsonb_build_object('status', 'ignored', 'reason', 'unknown_card_code');
END;
$function$;

-- 7. 延迟发放的补发函数 + 审批状态触发器
CREATE OR REPLACE FUNCTION public.apply_deferred_manager_card_purchases(
  p_manager_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_purchase record;
  v_manager public.managers;
  v_current_sort integer;
  v_target_sort integer;
  v_target_limit integer;
BEGIN
  SELECT * INTO v_manager FROM managers WHERE id = p_manager_id FOR UPDATE;
  IF NOT FOUND OR v_manager.certification_status <> 'approved' THEN
    RETURN;
  END IF;

  FOR v_purchase IN
    SELECT * FROM virtual_card_purchases
    WHERE target_manager_id = p_manager_id AND grant_status = 'deferred'
    ORDER BY created_at ASC
    FOR UPDATE
  LOOP
    SELECT sort_order INTO v_current_sort FROM membership_plans WHERE code = v_manager.membership_level;
    SELECT sort_order INTO v_target_sort FROM membership_plans WHERE code = v_purchase.target_plan_code;

    IF v_current_sort IS NOT NULL AND v_target_sort IS NOT NULL AND v_current_sort >= v_target_sort THEN
      UPDATE virtual_card_purchases
      SET grant_status = 'noop', grant_reason = 'already_at_or_above_target_plan', applied_at = now(), updated_at = now()
      WHERE id = v_purchase.id;
      CONTINUE;
    END IF;

    v_target_limit := CASE WHEN v_purchase.target_plan_code = 'basic' THEN 20 ELSE NULL END;

    UPDATE managers
    SET membership_level = v_purchase.target_plan_code,
        membership_enforcement_mode = 'enforced',
        client_limit_override = v_target_limit,
        membership_expires_at = COALESCE(v_purchase.expires_at, now() + interval '1 year'),
        membership_updated_at = now(),
        membership_note = CASE
          WHEN v_purchase.target_plan_code = 'basic' THEN '审核通过后自动生效：365管理师开通卡，客户名额覆盖为20'
          ELSE '审核通过后自动生效：高级管理师包'
        END
    WHERE id = p_manager_id;

    UPDATE virtual_card_purchases
    SET grant_status = 'applied', applied_at = now(), updated_at = now()
    WHERE id = v_purchase.id;

    SELECT * INTO v_manager FROM managers WHERE id = p_manager_id;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trigger_apply_deferred_card_purchases()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.certification_status = 'approved' AND OLD.certification_status IS DISTINCT FROM 'approved' THEN
    PERFORM public.apply_deferred_manager_card_purchases(NEW.id);
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_apply_deferred_card_purchases
AFTER UPDATE OF certification_status ON public.managers
FOR EACH ROW
EXECUTE FUNCTION public.trigger_apply_deferred_card_purchases();
