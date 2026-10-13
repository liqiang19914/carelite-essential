-- ============================================================
-- 审查修复 1：积分兑换商品的可见性门禁必须权威，不能被旧的分享授权绕过
-- 现金私域商品沿用 share_grants；积分商品改为「模块开通 + 本企业活跃客户」独立判定，
-- 命中即返回结果，不再向下穿透到 share_grants（现金商品转积分后旧授权会失效）
-- ============================================================
CREATE OR REPLACE FUNCTION public.can_view_product(p_product_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_source TEXT;
  v_owner UUID;
  v_status TEXT;
  v_sale_mode TEXT;
  v_root UUID;
BEGIN
  IF p_product_id IS NULL OR p_user_id IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT source_type, owner_manager_id, status, COALESCE(sale_mode, 'cash')
    INTO v_source, v_owner, v_status, v_sale_mode
    FROM products
    WHERE id = p_product_id;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  -- 1. admin 全可见
  IF EXISTS (
    SELECT 1 FROM profiles WHERE id = p_user_id AND role = 'admin'
  ) THEN
    RETURN TRUE;
  END IF;

  -- 2. 平台严选 + active：所有用户可见
  IF v_source = 'platform' AND v_status = 'active' THEN
    RETURN TRUE;
  END IF;

  -- 3. 平台严选 + 非 active：仅 admin（上面已拦截）
  IF v_source = 'platform' THEN
    RETURN FALSE;
  END IF;

  -- 4. 管理师私域：作者本人可见所有状态
  IF v_source = 'manager' AND v_owner = p_user_id THEN
    RETURN TRUE;
  END IF;

  IF v_source = 'manager' AND v_status = 'active' THEN
    -- 5. 积分兑换商品：门禁独立且权威。必须「平台已开通 + 商户已对客开放」，
    --    且调用者是本企业的活跃客户。不满足直接 FALSE，绝不回落到 share_grants ——
    --    否则现金商品转成积分后，旧的定向/全客户授权会在模块关闭后仍然放行。
    IF v_sale_mode = 'points' THEN
      IF v_owner IS NULL THEN
        RETURN FALSE;
      END IF;
      v_root := get_enterprise_root_manager_id(v_owner);
      IF v_root IS NULL THEN
        RETURN FALSE;
      END IF;
      RETURN EXISTS (
        SELECT 1 FROM merchant_module_grants g
        WHERE g.manager_id = v_root
          AND g.module_key = 'points_exchange'
          AND g.grant_status = 'granted'
          AND g.is_enabled = TRUE
      ) AND EXISTS (
        SELECT 1 FROM client_relations cr
        WHERE cr.client_id = p_user_id
          AND cr.status = 'active'
          AND get_enterprise_root_manager_id(cr.manager_id) = v_root
      );
    END IF;

    -- 6. 现金私域 active：通过 share_grants 显式授权才可见
    -- 6.1 specific 直接授权给该用户
    IF EXISTS (
      SELECT 1 FROM product_share_grants g
      WHERE g.product_id = p_product_id
        AND g.audience = 'specific'
        AND g.client_id = p_user_id
        AND g.revoked_at IS NULL
        AND (g.expires_at IS NULL OR g.expires_at > NOW())
    ) THEN RETURN TRUE; END IF;

    -- 6.2 all_clients：用户是该管理师的活跃客户
    IF EXISTS (
      SELECT 1 FROM product_share_grants g
      INNER JOIN client_relations cr
        ON cr.manager_id = g.manager_id
       AND cr.client_id = p_user_id
       AND cr.status = 'active'
      WHERE g.product_id = p_product_id
        AND g.audience = 'all_clients'
        AND g.revoked_at IS NULL
        AND (g.expires_at IS NULL OR g.expires_at > NOW())
    ) THEN RETURN TRUE; END IF;

    -- 6.3 tag：用户在该管理师的标签下
    IF EXISTS (
      SELECT 1 FROM product_share_grants g
      INNER JOIN client_relations cr
        ON cr.manager_id = g.manager_id
       AND cr.client_id = p_user_id
       AND cr.status = 'active'
      INNER JOIN client_tag_relations ctr
        ON ctr.client_relation_id = cr.id
       AND ctr.tag_id = g.tag_id
      WHERE g.product_id = p_product_id
        AND g.audience = 'tag'
        AND g.revoked_at IS NULL
        AND (g.expires_at IS NULL OR g.expires_at > NOW())
    ) THEN RETURN TRUE; END IF;
  END IF;

  RETURN FALSE;
END;
$function$;

-- ============================================================
-- 审查修复 2：积分下单必须复核可见性
-- 原来只校验状态/销售方式/库存，任何人拿到商品 UUID 都能兑换商户的积分商品——
-- 解绑、商户关闭开关、平台撤销授权后旧链接依然可下单。改为统一走 can_view_product。
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_points_order(p_out_trade_no text, p_product_id uuid, p_quantity integer, p_address_id uuid DEFAULT NULL::uuid, p_remark text DEFAULT ''::text)
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

  -- 可见性复核：商户积分商品要求「本企业活跃客户 + 模块对客开放」，
  -- 平台积分商品对所有用户可见。绕过列表页直接拿 UUID 下单也必须过这道闸。
  IF NOT public.can_view_product(p_product_id, v_uid) THEN
    RAISE EXCEPTION '这件商品当前不向你开放兑换' USING ERRCODE = '42501';
  END IF;

  -- 第一把锁：SKU 行
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

  PERFORM public._post_points_delta(
    v_uid, -v_cost, 'points_redeem',
    '积分兑换「' || v_product.title || '」（单号 ' || v_otn || '）',
    'points_redeem:' || v_otn,
    'order', v_row.id, NULL
  );

  RETURN v_row;
END;
$function$;

-- ============================================================
-- 审查修复 3：分享链接兜底详情不能成为积分商品的旁路
-- 该接口原本服务「现金私域商品分享链接」场景（拿到链接即可看详情）。
-- 积分商品不走分享链接，必须过可见性判定，否则任何人凭 UUID 就能看到并进入兑换页。
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_active_product_detail_for_link(p_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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

  IF v_product.source_type = 'manager'
     AND COALESCE(v_product.sale_mode, 'cash') = 'points'
     AND NOT can_view_product(p_product_id, v_uid) THEN
    RAISE EXCEPTION 'forbidden: product not visible';
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
$function$;

-- ============================================================
-- 审查修复 4：客户端积分专区必须按「自己绑定的那家商户」显式限定
-- 原来前端只按 source/status/sale_mode 取数，靠 RLS 兜底；绑定多家的客户会拿到多家商品。
-- 改为服务端解析归属企业（与积分专区开关同一套 _my_bound_root_manager_id），显式限定 + 分页上限。
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_my_merchant_points_products(p_limit integer DEFAULT 60)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid   uuid := auth.uid();
  v_root  uuid;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 60), 1), 200);
  v_out   jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  v_root := _my_bound_root_manager_id();
  IF v_root IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM merchant_module_grants g
    WHERE g.manager_id = v_root
      AND g.module_key = 'points_exchange'
      AND g.grant_status = 'granted'
      AND g.is_enabled = TRUE
  ) THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(row_json ORDER BY sort_weight DESC, created_at DESC), '[]'::jsonb)
    INTO v_out
  FROM (
    SELECT
      p.sort_weight,
      p.created_at,
      to_jsonb(p) || jsonb_build_object(
        'product_skus',
        COALESCE(
          (SELECT jsonb_agg(to_jsonb(s)) FROM product_skus s WHERE s.product_id = p.id),
          '[]'::jsonb
        )
      ) AS row_json
    FROM products p
    WHERE p.source_type = 'manager'
      AND p.status = 'active'
      AND COALESCE(p.sale_mode, 'cash') = 'points'
      AND p.owner_manager_id IS NOT NULL
      AND get_enterprise_root_manager_id(p.owner_manager_id) = v_root
    ORDER BY p.sort_weight DESC, p.created_at DESC
    LIMIT v_limit
  ) t;

  RETURN v_out;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_my_merchant_points_products(integer) TO authenticated;

-- ============================================================
-- 审查修复 5：商品字段与价格必须同一事务落库
-- 编辑器原来先改商品（含 sale_mode / status），再单独写 SKU；第二步失败会留下
-- 「已提交审核但积分价还是 0」或「已转现金但售价还是 0」的半成品，而平台审核只看状态就能放行。
-- ============================================================
CREATE OR REPLACE FUNCTION public.manager_save_product_with_sku(
  p_id uuid,
  p_patch jsonb,
  p_expected_status text[] DEFAULT NULL,
  p_price_cents integer DEFAULT 0,
  p_original_price_cents integer DEFAULT NULL,
  p_stock integer DEFAULT 0,
  p_points_price integer DEFAULT NULL
)
RETURNS products
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_row products;
BEGIN
  IF p_id IS NULL THEN
    RAISE EXCEPTION '缺少商品 ID' USING ERRCODE = '22023';
  END IF;

  -- 先落商品字段（含 sale_mode / status），再落价格：
  -- 这样 SKU 校验能按最终的销售方式判定（积分必须有积分价、现金价必须为 0），
  -- 任一步失败整个事务回滚，不会留下前后不一致的商品。
  v_row := manager_update_product(p_id, p_patch, p_expected_status);

  PERFORM manager_update_default_product_sku(
    p_id, p_price_cents, p_original_price_cents, p_stock, p_points_price
  );

  RETURN v_row;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_save_product_with_sku(uuid, jsonb, text[], integer, integer, integer, integer) TO authenticated;