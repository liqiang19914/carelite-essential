-- ============================================================================
-- 门店体系 RPC 组 B：门店商城公开查询 + 线下订单状态机
-- 下单/自证/取消/核销全部条件更新，重复提交幂等；中文错误直接可执行。
-- ============================================================================

-- ── 匿名：门店商城商品列表（短码解析，服务端可信；不传 store_id）───
CREATE OR REPLACE FUNCTION public.get_store_products(p_store_code TEXT)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_store public.stores%ROWTYPE;
  v_items JSON;
  v_root_on BOOLEAN;
BEGIN
  IF p_store_code IS NULL OR btrim(p_store_code) = '' THEN
    RETURN json_build_object('store', NULL, 'items', '[]'::JSON, 'reason', 'missing_code');
  END IF;
  SELECT * INTO v_store FROM public.stores WHERE short_code = btrim(p_store_code);
  IF NOT FOUND THEN
    RETURN json_build_object('store', NULL, 'items', '[]'::JSON, 'reason', 'not_found');
  END IF;

  SELECT public._store_module_on(v_store.root_manager_id) INTO v_root_on;
  IF v_store.status <> 'active' OR NOT COALESCE(v_root_on, false) THEN
    RETURN json_build_object(
      'store', json_build_object(
        'id', v_store.id, 'short_code', v_store.short_code,
        'name', v_store.name, 'status', v_store.status,
        'root_manager_id', v_store.root_manager_id,
        'receipt_qr_url', v_store.receipt_qr_url, 'disabled_at', v_store.disabled_at
      ),
      'items', '[]'::JSON,
      'reason', 'store_disabled'
    );
  END IF;

  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT p.id, p.title, p.subtitle, p.cover_image_url,
           p.category, p.tags, p.sales_count,
           sku.price_cents, sku.stock, sku.id AS sku_id,
           p.requires_shipping, p.store_only
    FROM public.store_product_grants g
    JOIN public.products p ON p.id = g.product_id
    JOIN public.product_skus sku ON sku.product_id = p.id AND sku.is_default = true
    WHERE g.store_id = v_store.id
      AND g.is_enabled = true
      AND p.status = 'active'
      AND p.source_type = 'manager'
      AND p.sale_mode = 'cash'
      AND p.owner_manager_id IS NOT NULL
      AND public.get_enterprise_root_manager_id(p.owner_manager_id) = v_store.root_manager_id
      AND sku.is_active = true
      AND sku.stock > 0
  ) t;

  RETURN json_build_object(
    'store', json_build_object(
      'id', v_store.id, 'short_code', v_store.short_code,
      'name', v_store.name, 'status', v_store.status,
      'root_manager_id', v_store.root_manager_id,
      'receipt_qr_url', v_store.receipt_qr_url, 'disabled_at', v_store.disabled_at
    ),
    'items', COALESCE(v_items, '[]'::JSON),
    'reason', 'ok'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_store_products(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_store_products(TEXT) TO anon, authenticated;

-- ── 匿名：门店商城商品详情（含门店收款信息，供结算页展示）─────────
CREATE OR REPLACE FUNCTION public.get_store_product_detail(
  p_store_code TEXT,
  p_product_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_store public.stores%ROWTYPE;
  v_product public.products%ROWTYPE;
  v_sku public.product_skus%ROWTYPE;
  v_granted BOOLEAN;
BEGIN
  IF p_store_code IS NULL OR p_product_id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_store FROM public.stores WHERE short_code = btrim(p_store_code);
  IF NOT FOUND OR v_store.status <> 'active' THEN
    RETURN NULL;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.store_product_grants g
    WHERE g.store_id = v_store.id AND g.product_id = p_product_id AND g.is_enabled = true
  ) INTO v_granted;
  IF NOT COALESCE(v_granted, false) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_product FROM public.products
  WHERE id = p_product_id AND status = 'active'
    AND source_type = 'manager' AND sale_mode = 'cash';
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF public.get_enterprise_root_manager_id(v_product.owner_manager_id) IS DISTINCT FROM v_store.root_manager_id THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_sku FROM public.product_skus
  WHERE product_id = p_product_id AND is_default = true AND is_active = true
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN json_build_object(
    'store', json_build_object(
      'id', v_store.id, 'short_code', v_store.short_code, 'name', v_store.name,
      'receipt_qr_url', v_store.receipt_qr_url, 'root_manager_id', v_store.root_manager_id
    ),
    'product', json_build_object(
      'id', v_product.id, 'title', v_product.title, 'subtitle', v_product.subtitle,
      'description', v_product.description, 'description_doc', v_product.description_doc,
      'cover_image_url', v_product.cover_image_url, 'gallery_images', v_product.gallery_images,
      'category', v_product.category, 'tags', v_product.tags,
      'sales_count', v_product.sales_count, 'requires_shipping', v_product.requires_shipping,
      'store_only', v_product.store_only,
      'sku_id', v_sku.id, 'price_cents', v_sku.price_cents, 'stock', v_sku.stock
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_store_product_detail(TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_store_product_detail(TEXT, UUID) TO anon, authenticated;

-- ── 下单：线下门店订单（短码服务端解析门店，免收货地址，创建即预扣库存）─
CREATE OR REPLACE FUNCTION public.create_offline_store_order(
  p_out_trade_no TEXT,
  p_store_code TEXT,
  p_product_id UUID,
  p_quantity INTEGER,
  p_contact_name TEXT,
  p_contact_phone TEXT,
  p_remark TEXT DEFAULT ''
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_store public.stores%ROWTYPE;
  v_product public.products%ROWTYPE;
  v_sku public.product_skus%ROWTYPE;
  v_otn TEXT;
  v_total INTEGER;
  v_row public.orders%ROWTYPE;
  v_name TEXT := btrim(COALESCE(p_contact_name, ''));
  v_phone TEXT := btrim(COALESCE(p_contact_phone, ''));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = v_uid AND role = 'user' AND is_disabled = false
  ) THEN
    RAISE EXCEPTION '只有用户端账号可以下单' USING ERRCODE = '42501';
  END IF;

  v_otn := btrim(COALESCE(p_out_trade_no, ''));
  IF v_otn = '' OR char_length(v_otn) > 64 THEN
    RAISE EXCEPTION '订单号不合法' USING ERRCODE = '22023';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 9999 THEN
    RAISE EXCEPTION '购买数量必须在 1 到 9999 之间' USING ERRCODE = '22023';
  END IF;
  IF v_name = '' OR char_length(v_name) > 50 THEN
    RAISE EXCEPTION '联系人姓名不能为空且不超过 50 字' USING ERRCODE = '22023';
  END IF;
  IF v_phone !~ '^1[3-9][0-9]{9}$' THEN
    RAISE EXCEPTION '手机号格式不正确' USING ERRCODE = '22023';
  END IF;
  IF char_length(COALESCE(p_remark, '')) > 200 THEN
    RAISE EXCEPTION '备注最多 200 字' USING ERRCODE = '22023';
  END IF;

  -- 门店由短码服务端解析，前端传的 store_id 一律不可信
  SELECT * INTO v_store FROM public.stores WHERE short_code = btrim(p_store_code);
  IF NOT FOUND THEN
    RAISE EXCEPTION '门店不存在，请重新扫码进入' USING ERRCODE = '22023';
  END IF;
  IF v_store.status <> 'active' THEN
    RAISE EXCEPTION '这家门店已暂停营业，暂时无法下单' USING ERRCODE = '22023';
  END IF;
  IF NOT public._store_module_on(v_store.root_manager_id) THEN
    RAISE EXCEPTION '这家门店暂时不接单' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_product FROM public.products WHERE id = p_product_id;
  IF NOT FOUND OR v_product.status <> 'active' THEN
    RAISE EXCEPTION '商品不存在或已下架' USING ERRCODE = '22023';
  END IF;
  IF v_product.source_type <> 'manager' OR v_product.sale_mode <> 'cash' THEN
    RAISE EXCEPTION '这件商品不支持在门店购买' USING ERRCODE = '22023';
  END IF;
  IF public.get_enterprise_root_manager_id(v_product.owner_manager_id) IS DISTINCT FROM v_store.root_manager_id THEN
    RAISE EXCEPTION '这件商品不属于这家门店' USING ERRCODE = '22023';
  END IF;

  -- 授权校验：商品下架/取消勾选只影响新单
  IF NOT EXISTS (
    SELECT 1 FROM public.store_product_grants g
    WHERE g.store_id = v_store.id AND g.product_id = p_product_id AND g.is_enabled = true
  ) THEN
    RAISE EXCEPTION '这件商品已不在门店售卖，请刷新后重试' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_sku
  FROM public.product_skus
  WHERE product_id = p_product_id AND is_default = true
  LIMIT 1;
  IF NOT FOUND OR NOT v_sku.is_active THEN
    RAISE EXCEPTION '商品规格不可用' USING ERRCODE = '22023';
  END IF;
  IF v_sku.price_cents <= 0 THEN
    RAISE EXCEPTION '商品价格未配置' USING ERRCODE = '22023';
  END IF;

  -- 锁 SKU 行再校验库存，避免并发超卖
  PERFORM 1 FROM public.product_skus WHERE id = v_sku.id FOR UPDATE;
  SELECT stock INTO v_sku.stock FROM public.product_skus WHERE id = v_sku.id;
  IF v_sku.stock < p_quantity THEN
    RAISE EXCEPTION '库存不足，当前仅剩 % 件', v_sku.stock USING ERRCODE = '22023';
  END IF;

  v_total := v_sku.price_cents * p_quantity;

  INSERT INTO public.orders (
    out_trade_no, user_id, product_id, sku_id,
    product_title_snapshot, cover_image_snapshot,
    unit_price_cents, quantity, total_amount_cents,
    product_source_type_snapshot, owner_manager_id_snapshot,
    shop_manager_id_snapshot,
    status, preferred_payment_method, payment_method,
    contact_name, contact_phone, remark,
    requires_shipping_snapshot,
    store_id, payment_channel, offline_status,
    store_name_snapshot, receipt_qr_url_snapshot
  ) VALUES (
    v_otn, v_uid, v_product.id, v_sku.id,
    v_product.title, COALESCE(v_product.cover_image_url, ''),
    v_sku.price_cents, p_quantity, v_total,
    v_product.source_type, v_product.owner_manager_id,
    v_store.root_manager_id,
    'pending', 'wechat', 'offline_store',
    v_name, v_phone, COALESCE(p_remark, ''),
    COALESCE(v_product.requires_shipping, true),
    v_store.id, 'offline_store', 'awaiting_payment',
    v_store.name, v_store.receipt_qr_url
  )
  RETURNING * INTO v_row;

  -- 创建即预扣库存（线下交易先锁货，取消时幂等返还）
  UPDATE public.product_skus
     SET stock = stock - p_quantity, updated_at = now()
   WHERE id = v_sku.id;

  UPDATE public.orders
     SET stock_decremented = true
   WHERE id = v_row.id;

  RETURN json_build_object(
    'order', json_build_object(
      'id', v_row.id, 'out_trade_no', v_row.out_trade_no,
      'total_amount_cents', v_row.total_amount_cents,
      'offline_status', v_row.offline_status,
      'store_name', v_row.store_name_snapshot,
      'receipt_qr_url', v_row.receipt_qr_url_snapshot,
      'product_title', v_row.product_title_snapshot,
      'quantity', v_row.quantity
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.create_offline_store_order(TEXT, TEXT, UUID, INTEGER, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_offline_store_order(TEXT, TEXT, UUID, INTEGER, TEXT, TEXT, TEXT) TO authenticated;

-- ── 客户自证付款：awaiting_payment → awaiting_verification（幂等）──
CREATE OR REPLACE FUNCTION public.claim_offline_store_payment(p_order_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_order public.orders%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND OR v_order.user_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF v_order.payment_channel <> 'offline_store' THEN
    RAISE EXCEPTION '这不是门店线下订单' USING ERRCODE = '22023';
  END IF;
  IF v_order.offline_status = 'verified' THEN
    RAISE EXCEPTION '订单已经核销过了' USING ERRCODE = '22023';
  END IF;
  IF v_order.offline_status = 'cancelled' THEN
    RAISE EXCEPTION '订单已取消' USING ERRCODE = '22023';
  END IF;

  UPDATE public.orders
     SET offline_status = 'awaiting_verification',
         offline_claimed_at = COALESCE(offline_claimed_at, now()),
         updated_at = now()
   WHERE id = v_order.id AND offline_status = 'awaiting_payment';

  RETURN json_build_object('success', true, 'offline_status', 'awaiting_verification');
END;
$function$;

REVOKE ALL ON FUNCTION public.claim_offline_store_payment(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_offline_store_payment(UUID) TO authenticated;

-- ── 取消线下单：未核销可取消，预扣库存幂等返还 ───────────────────
CREATE OR REPLACE FUNCTION public.cancel_offline_store_order(p_order_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_order public.orders%ROWTYPE;
  v_is_operator BOOLEAN;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF v_order.payment_channel <> 'offline_store' THEN
    RAISE EXCEPTION '这不是门店线下订单' USING ERRCODE = '22023';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  SELECT EXISTS (
    SELECT 1 FROM public.stores s
    WHERE s.id = v_order.store_id AND s.operator_user_id = v_uid
  ) INTO v_is_operator;

  IF v_order.user_id IS DISTINCT FROM v_uid
     AND NOT COALESCE(v_is_operator, false)
     AND v_root IS DISTINCT FROM v_order.shop_manager_id_snapshot THEN
    RAISE EXCEPTION '你没有操作这个订单的权限' USING ERRCODE = '42501';
  END IF;

  IF v_order.offline_status = 'verified' THEN
    RAISE EXCEPTION '订单已经核销，无法取消，请走退货流程' USING ERRCODE = '22023';
  END IF;
  IF v_order.offline_status = 'cancelled' THEN
    RETURN json_build_object('success', true, 'already', true);
  END IF;

  UPDATE public.orders
     SET offline_status = 'cancelled',
         status = 'cancelled',
         cancelled_at = now(),
         updated_at = now()
   WHERE id = v_order.id AND offline_status IN ('awaiting_payment','awaiting_verification');

  IF v_order.stock_decremented THEN
    UPDATE public.product_skus
       SET stock = stock + v_order.quantity, updated_at = now()
     WHERE id = v_order.sku_id;
    UPDATE public.orders
       SET stock_decremented = false
     WHERE id = v_order.id AND offline_status = 'cancelled';
  END IF;

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.cancel_offline_store_order(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_offline_store_order(UUID) TO authenticated;

-- ── 门店核销：锁单 + 经营者与门店归属校验 + 幂等 ─────────────────
CREATE OR REPLACE FUNCTION public.verify_offline_store_order(p_order_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_order public.orders%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF v_order.payment_channel <> 'offline_store' THEN
    RAISE EXCEPTION '这不是门店线下订单' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.stores s
    WHERE s.id = v_order.store_id
      AND s.operator_user_id = v_uid
      AND s.status = 'active'
  ) THEN
    RAISE EXCEPTION '只有这家门店的经营账号才能核销' USING ERRCODE = '42501';
  END IF;

  IF v_order.offline_status = 'verified' THEN
    RETURN json_build_object('success', true, 'already', true);
  END IF;
  IF v_order.offline_status = 'cancelled' THEN
    RAISE EXCEPTION '订单已取消，无法核销' USING ERRCODE = '22023';
  END IF;
  IF v_order.offline_status IS DISTINCT FROM 'awaiting_verification' THEN
    RAISE EXCEPTION '客户还没有确认到店付款，暂时不能核销' USING ERRCODE = '22023';
  END IF;

  UPDATE public.orders
     SET offline_status = 'verified',
         status = 'paid',
         payment_method = 'offline_store',
         paid_at = now(),
         fulfillment_status = 'completed',
         completed_at = now(),
         verified_by = v_uid,
         verified_at = now(),
         updated_at = now()
   WHERE id = v_order.id;

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.verify_offline_store_order(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_offline_store_order(UUID) TO authenticated;

-- ── 门店经营端：本店线下订单列表（分页）──────────────────────────
CREATE OR REPLACE FUNCTION public.list_my_store_orders(
  p_store_id UUID,
  p_status TEXT DEFAULT 'active',
  p_limit INTEGER DEFAULT 20,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_store public.stores%ROWTYPE;
  v_items JSON;
  v_total INTEGER;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_store FROM public.stores WHERE id = p_store_id;
  IF NOT FOUND OR v_store.operator_user_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION '你没有查看这家门店订单的权限' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM public.orders o
  WHERE o.store_id = v_store.id
    AND o.payment_channel = 'offline_store'
    AND (
      (p_status = 'active' AND o.offline_status IN ('awaiting_payment','awaiting_verification'))
      OR (p_status = 'verified' AND o.offline_status = 'verified')
      OR (p_status = 'cancelled' AND o.offline_status = 'cancelled')
      OR (p_status = 'all')
    );

  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT o.id, o.out_trade_no, o.product_title_snapshot, o.cover_image_snapshot,
           o.unit_price_cents, o.quantity, o.total_amount_cents,
           o.contact_name, o.contact_phone, o.remark,
           o.offline_status, o.offline_claimed_at, o.verified_at, o.created_at,
           o.requires_shipping_snapshot, o.user_id
    FROM public.orders o
    WHERE o.store_id = v_store.id
      AND o.payment_channel = 'offline_store'
      AND (
        (p_status = 'active' AND o.offline_status IN ('awaiting_payment','awaiting_verification'))
        OR (p_status = 'verified' AND o.offline_status = 'verified')
        OR (p_status = 'cancelled' AND o.offline_status = 'cancelled')
        OR (p_status = 'all')
      )
    ORDER BY o.created_at DESC
    LIMIT GREATEST(LEAST(p_limit, 100), 1)
    OFFSET GREATEST(p_offset, 0)
  ) t;

  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON), 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_my_store_orders(UUID, TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_store_orders(UUID, TEXT, INTEGER, INTEGER) TO authenticated;

-- ── 客户：我的线下门店订单（到店核销入口用）───────────────────────
CREATE OR REPLACE FUNCTION public.list_my_offline_orders()
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_items JSON;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT o.id, o.out_trade_no, o.product_title_snapshot, o.cover_image_snapshot,
           o.total_amount_cents, o.quantity, o.created_at,
           o.offline_status, o.offline_claimed_at, o.verified_at,
           o.store_name_snapshot, o.receipt_qr_url_snapshot, o.requires_shipping_snapshot
    FROM public.orders o
    WHERE o.user_id = v_uid
      AND o.payment_channel = 'offline_store'
    ORDER BY o.created_at DESC
    LIMIT 100
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;

REVOKE ALL ON FUNCTION public.list_my_offline_orders() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_offline_orders() TO authenticated;