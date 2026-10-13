-- 282: 门店核销码升级（6 位数字码按店唯一、兼容旧码、地址导航、错误提示）
-- 1) 核销码列 + 按店唯一索引（旧订单为空，兼容旧码）
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS verify_code text;
CREATE UNIQUE INDEX IF NOT EXISTS orders_store_verify_code_key
  ON public.orders (store_id, verify_code)
  WHERE verify_code IS NOT NULL;

-- 2) 确认付款时生成 6 位按店唯一核销码（幂等：已有码不重生成）
CREATE OR REPLACE FUNCTION public.claim_offline_store_payment(p_order_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_order public.orders%ROWTYPE;
  v_code TEXT;
  v_has BOOLEAN;
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

  -- 已确认付款且还没有核销码时，生成 6 位按店唯一码；撞码（极罕见）重试，索引兜底
  SELECT (verify_code IS NULL AND offline_status = 'awaiting_verification') INTO v_has
    FROM public.orders WHERE id = v_order.id;
  IF v_has THEN
    FOR i IN 1..50 LOOP
      v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');
      BEGIN
        UPDATE public.orders SET verify_code = v_code
         WHERE id = v_order.id AND verify_code IS NULL;
        EXIT WHEN FOUND;
      EXCEPTION WHEN unique_violation THEN
        NULL;
      END;
      SELECT (verify_code IS NOT NULL) INTO v_has FROM public.orders WHERE id = v_order.id;
      EXIT WHEN v_has;
    END LOOP;
  END IF;

  RETURN json_build_object('success', true, 'offline_status', 'awaiting_verification');
END;
$function$;

REVOKE ALL ON FUNCTION public.claim_offline_store_payment(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_offline_store_payment(UUID) TO authenticated;

-- 3) 预览核销：兼容 v1 扫码串与 6 位数字码；跨店明确提示「这不是本店订单」
DROP FUNCTION IF EXISTS public.preview_offline_store_order_by_code(text);
CREATE OR REPLACE FUNCTION public.preview_offline_store_order_by_code(p_code text, p_store_id uuid DEFAULT NULL)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_no text := public.parse_store_order_code(btrim(coalesce(p_code, '')));
  v_order public.orders%ROWTYPE;
  v_is_member boolean;
  v_store_name text;
  v_scope uuid := p_store_id;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF v_no = '' THEN
    RAISE EXCEPTION '核销码不能为空' USING ERRCODE = '22023';
  END IF;

  IF v_no ~ '^[0-9]{6}$' THEN
    -- 6 位数字码：按店查找。未传门店时取调用者的成员门店（唯一成员时）。
    IF v_scope IS NULL THEN
      SELECT m.store_id INTO v_scope
        FROM public.store_members m
       WHERE m.user_id = v_uid AND m.status = 'active'
       ORDER BY m.created_at ASC
       LIMIT 1;
    END IF;
    IF v_scope IS NULL THEN
      RAISE EXCEPTION '这不是本店订单' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_order FROM public.orders
     WHERE verify_code = v_no
       AND store_id = v_scope
       AND payment_channel = 'offline_store';
    IF NOT FOUND THEN
      IF EXISTS (
        SELECT 1 FROM public.orders
         WHERE verify_code = v_no AND payment_channel = 'offline_store'
      ) THEN
        RAISE EXCEPTION '这不是本店订单' USING ERRCODE = '22023';
      ELSE
        RAISE EXCEPTION '核销码无效或已失效' USING ERRCODE = '22023';
      END IF;
    END IF;
  ELSE
    SELECT * INTO v_order FROM public.orders
     WHERE out_trade_no = v_no AND payment_channel = 'offline_store';
    IF NOT FOUND THEN
      RAISE EXCEPTION '没有找到这张核销码对应的订单' USING ERRCODE = '22023';
    END IF;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.store_members m
    WHERE m.store_id = v_order.store_id AND m.user_id = v_uid AND m.status = 'active'
  ) INTO v_is_member;
  IF NOT coalesce(v_is_member, false)
     AND NOT public._can_admin_store(v_order.store_id) THEN
    RAISE EXCEPTION '这不是本店订单' USING ERRCODE = '22023';
  END IF;

  SELECT name INTO v_store_name FROM public.stores WHERE id = v_order.store_id;

  RETURN json_build_object(
    'order_id', v_order.id,
    'out_trade_no', v_order.out_trade_no,
    'product_title', v_order.product_title_snapshot,
    'cover_image_url', v_order.cover_image_snapshot,
    'quantity', v_order.quantity,
    'total_amount_cents', v_order.total_amount_cents,
    'contact_name', v_order.contact_name,
    'contact_phone', CASE
      WHEN public.is_admin(v_uid) THEN v_order.contact_phone
      WHEN v_order.contact_phone ~ '^1[0-9]{10}$' THEN left(v_order.contact_phone, 3) || '****' || right(v_order.contact_phone, 4)
      ELSE v_order.contact_phone
    END,
    'remark', v_order.remark,
    'offline_status', v_order.offline_status,
    'store_name', coalesce(v_store_name, ''),
    'created_at', v_order.created_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.preview_offline_store_order_by_code(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.preview_offline_store_order_by_code(text, uuid) TO authenticated;

-- 4) 按码核销：同上支持 6 位数字码与跨店提示
DROP FUNCTION IF EXISTS public.verify_offline_store_order_by_code(text);
CREATE OR REPLACE FUNCTION public.verify_offline_store_order_by_code(p_code text, p_store_id uuid DEFAULT NULL)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_no text := public.parse_store_order_code(btrim(coalesce(p_code, '')));
  v_order public.orders%ROWTYPE;
  v_scope uuid := p_store_id;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF v_no = '' THEN
    RAISE EXCEPTION '核销码不能为空' USING ERRCODE = '22023';
  END IF;

  IF v_no ~ '^[0-9]{6}$' THEN
    IF v_scope IS NULL THEN
      SELECT m.store_id INTO v_scope
        FROM public.store_members m
       WHERE m.user_id = v_uid AND m.status = 'active'
       ORDER BY m.created_at ASC
       LIMIT 1;
    END IF;
    IF v_scope IS NULL THEN
      RAISE EXCEPTION '这不是本店订单' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_order FROM public.orders
     WHERE verify_code = v_no
       AND store_id = v_scope
       AND payment_channel = 'offline_store'
     FOR UPDATE;
    IF NOT FOUND THEN
      IF EXISTS (
        SELECT 1 FROM public.orders
         WHERE verify_code = v_no AND payment_channel = 'offline_store'
      ) THEN
        RAISE EXCEPTION '这不是本店订单' USING ERRCODE = '22023';
      ELSE
        RAISE EXCEPTION '核销码无效或已失效' USING ERRCODE = '22023';
      END IF;
    END IF;
  ELSE
    SELECT * INTO v_order FROM public.orders
     WHERE out_trade_no = v_no AND payment_channel = 'offline_store'
     FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION '没有找到这张核销码对应的订单' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members m
    JOIN public.stores s ON s.id = m.store_id
    WHERE s.id = v_order.store_id AND m.user_id = v_uid AND m.status = 'active'
      AND s.status = 'active'
  ) AND NOT public._can_admin_store(v_order.store_id) THEN
    RAISE EXCEPTION '这不是本店订单' USING ERRCODE = '22023';
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
         payment_method = 'offline',
         paid_at = now(),
         completed_at = now(),
         verified_by = v_uid,
         verified_at = now(),
         updated_at = now()
   WHERE id = v_order.id;

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.verify_offline_store_order_by_code(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_offline_store_order_by_code(text, uuid) TO authenticated;

-- 5) 我的线下订单：带核销码 + 门店地址/电话（放大展示与复制导航）
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
    SELECT o.id, o.out_trade_no, o.verify_code,
           o.product_title_snapshot, o.cover_image_snapshot,
           o.total_amount_cents, o.quantity, o.created_at,
           o.offline_status, o.offline_claimed_at, o.verified_at,
           o.store_name_snapshot, o.receipt_qr_url_snapshot, o.requires_shipping_snapshot,
           s.address AS store_address,
           s.phone AS store_phone
    FROM public.orders o
    LEFT JOIN public.stores s ON s.id = o.store_id
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