-- 线下门店订单的 payment_method 用 'offline' 标记（收款走门店自备码，不属线上支付）
ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_payment_method_check;
ALTER TABLE public.orders ADD CONSTRAINT orders_payment_method_check
  CHECK (payment_method = ANY (ARRAY['wechat'::text, 'alipay'::text, 'offline'::text]));

-- 下单函数：payment_method 改用 'offline'
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
    shipping_province, shipping_city, shipping_district, shipping_address_detail,
    requires_shipping_snapshot,
    store_id, payment_channel, offline_status,
    store_name_snapshot, receipt_qr_url_snapshot
  ) VALUES (
    v_otn, v_uid, v_product.id, v_sku.id,
    v_product.title, COALESCE(v_product.cover_image_url, ''),
    v_sku.price_cents, p_quantity, v_total,
    v_product.source_type, v_product.owner_manager_id,
    v_store.root_manager_id,
    'pending', 'wechat', 'offline',
    v_name, v_phone, COALESCE(p_remark, ''),
    '', '', '', '',
    COALESCE(v_product.requires_shipping, true),
    v_store.id, 'offline_store', 'awaiting_payment',
    v_store.name, COALESCE(v_store.receipt_qr_url, '')
  )
  RETURNING * INTO v_row;

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