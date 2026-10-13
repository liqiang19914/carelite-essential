-- ── 订单动作统一加 p_shop_root 并做作用域校验 ──
DROP FUNCTION IF EXISTS public.user_confirm_receipt(text);

CREATE OR REPLACE FUNCTION public.user_confirm_receipt(p_out_trade_no text, p_shop_root uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid   uuid := auth.uid();
  v_order public.orders;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_order FROM public.orders
  WHERE out_trade_no = p_out_trade_no AND user_id = v_uid
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF NOT public._owner_in_shop_scope(v_order.owner_manager_id_snapshot, p_shop_root) THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF v_order.fulfillment_status IN ('received', 'completed') THEN
    RETURN jsonb_build_object('fulfillment_status', v_order.fulfillment_status,
                              'received_at', v_order.received_at);
  END IF;
  IF v_order.fulfillment_status IS DISTINCT FROM 'shipped' THEN
    RAISE EXCEPTION '该订单还没有发货' USING ERRCODE = '22023';
  END IF;

  UPDATE public.orders
  SET fulfillment_status = 'received',
      received_at        = now(),
      updated_at         = now()
  WHERE id = v_order.id
  RETURNING * INTO v_order;

  RETURN jsonb_build_object('fulfillment_status', v_order.fulfillment_status,
                            'received_at', v_order.received_at);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.user_confirm_receipt(text, uuid) TO authenticated, anon, service_role;

DROP FUNCTION IF EXISTS public.user_submit_order_review(text, integer, text, jsonb);

CREATE OR REPLACE FUNCTION public.user_submit_order_review(p_out_trade_no text, p_rating integer, p_content text DEFAULT ''::text, p_images jsonb DEFAULT '[]'::jsonb, p_shop_root uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid     uuid := auth.uid();
  v_order   public.orders;
  v_ef      text;
  v_content text;
  v_images  jsonb;
  v_row     public.order_reviews;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;
  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
    RAISE EXCEPTION '请先给出 1 到 5 星的评分' USING ERRCODE = '22023';
  END IF;

  v_content := btrim(COALESCE(p_content, ''));
  IF char_length(v_content) > 500 THEN
    RAISE EXCEPTION '评价内容最多 500 字' USING ERRCODE = '22023';
  END IF;
  v_images := public._validate_image_array(p_images, 6);

  SELECT * INTO v_order FROM public.orders
  WHERE out_trade_no = p_out_trade_no AND user_id = v_uid
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF NOT public._owner_in_shop_scope(v_order.owner_manager_id_snapshot, p_shop_root) THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF v_order.status IS DISTINCT FROM 'paid' THEN
    RAISE EXCEPTION '只有已完成的订单可以评价' USING ERRCODE = '22023';
  END IF;

  v_ef := public._effective_fulfillment_status(v_order.fulfillment_status, v_order.auto_receive_at);
  IF v_ef NOT IN ('received', 'completed') AND v_order.fulfillment_status <> 'not_required' THEN
    RAISE EXCEPTION '请先确认收货后再评价' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (SELECT 1 FROM public.order_reviews WHERE order_id = v_order.id) THEN
    RAISE EXCEPTION '该订单已经评价过了' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.order_reviews (
    order_id, user_id, product_id, rating, content, images, is_public
  ) VALUES (
    v_order.id, v_uid, v_order.product_id, p_rating::smallint, v_content, v_images, false
  )
  RETURNING * INTO v_row;

  IF v_order.requires_shipping_snapshot = true THEN
    UPDATE public.orders
    SET fulfillment_status = 'completed',
        received_at        = COALESCE(received_at, auto_receive_at, now()),
        completed_at       = now(),
        updated_at         = now()
    WHERE id = v_order.id;
  END IF;

  RETURN to_jsonb(v_row);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.user_submit_order_review(text, integer, text, jsonb, uuid) TO authenticated, anon, service_role;

DROP FUNCTION IF EXISTS public.user_create_return_request(text, text, text, jsonb);

CREATE OR REPLACE FUNCTION public.user_create_return_request(p_out_trade_no text, p_reason_code text, p_reason_text text, p_images jsonb DEFAULT '[]'::jsonb, p_shop_root uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid     uuid := auth.uid();
  v_order   public.orders;
  v_pay     public.wechat_miniapp_pay_orders;
  v_scope   text;
  v_manager uuid;
  v_reason  text;
  v_images  jsonb;
  v_ef      text;
  v_row     public.order_return_requests;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;
  IF p_reason_code NOT IN ('quality', 'wrong_item', 'damaged',
                           'not_as_described', 'no_longer_needed', 'other') THEN
    RAISE EXCEPTION '请选择退货原因' USING ERRCODE = '22023';
  END IF;

  v_reason := btrim(COALESCE(p_reason_text, ''));
  IF v_reason = '' OR char_length(v_reason) > 500 THEN
    RAISE EXCEPTION '请填写退货说明（500 字以内）' USING ERRCODE = '22023';
  END IF;
  v_images := public._validate_image_array(p_images, 6);

  SELECT * INTO v_order FROM public.orders
  WHERE out_trade_no = p_out_trade_no AND user_id = v_uid
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF NOT public._owner_in_shop_scope(v_order.owner_manager_id_snapshot, p_shop_root) THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF v_order.status IS DISTINCT FROM 'paid' THEN
    RAISE EXCEPTION '只有已支付且未退款的订单可以申请退货' USING ERRCODE = '22023';
  END IF;

  v_ef := public._effective_fulfillment_status(v_order.fulfillment_status, v_order.auto_receive_at);
  IF v_ef = 'completed' THEN
    RAISE EXCEPTION '该订单已完成，如需售后请联系客服' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.order_return_requests r
    WHERE r.order_id = v_order.id AND r.status IN ('pending', 'approved')
  ) THEN
    RAISE EXCEPTION '已有一笔退货申请正在处理中' USING ERRCODE = '22023';
  END IF;

  IF v_order.pay_mode = 'points' THEN
    v_scope := 'platform';
    v_manager := NULL;
  ELSE
    SELECT * INTO v_pay FROM public.wechat_miniapp_pay_orders WHERE order_id = v_order.id;
    IF v_pay.id IS NOT NULL
       AND COALESCE(v_pay.payee_type, '') = 'manager'
       AND v_pay.payee_manager_id IS NOT NULL THEN
      v_scope := 'merchant';
      v_manager := v_pay.payee_manager_id;
    ELSE
      v_scope := 'platform';
      v_manager := NULL;
    END IF;
  END IF;

  INSERT INTO public.order_return_requests (
    order_id, user_id, handler_scope, handler_manager_id,
    status, reason_code, reason_text, images
  ) VALUES (
    v_order.id, v_uid, v_scope, v_manager,
    'pending', p_reason_code, v_reason, v_images
  )
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.user_create_return_request(text, text, text, jsonb, uuid) TO authenticated, anon, service_role;

DROP FUNCTION IF EXISTS public.user_cancel_points_order(text);

CREATE OR REPLACE FUNCTION public.user_cancel_points_order(p_out_trade_no text, p_shop_root uuid DEFAULT NULL::uuid)
 RETURNS orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.orders;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row
  FROM public.orders
  WHERE out_trade_no = p_out_trade_no AND user_id = v_uid
  FOR UPDATE;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF NOT public._owner_in_shop_scope(v_row.owner_manager_id_snapshot, p_shop_root) THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF v_row.pay_mode IS DISTINCT FROM 'points' THEN
    RAISE EXCEPTION '该订单不是积分兑换单' USING ERRCODE = '22023';
  END IF;
  IF v_row.status IS DISTINCT FROM 'paid' THEN
    RAISE EXCEPTION '该订单当前状态不可取消' USING ERRCODE = '22023';
  END IF;
  IF v_row.fulfillment_status NOT IN ('not_required', 'pending_ship') THEN
    RAISE EXCEPTION '商品已发出，无法取消，请提交退货申请' USING ERRCODE = '22023';
  END IF;

  IF v_row.sku_id IS NOT NULL THEN
    PERFORM 1 FROM public.product_skus WHERE id = v_row.sku_id FOR UPDATE;
    UPDATE public.product_skus
    SET stock = stock + v_row.quantity, updated_at = now()
    WHERE id = v_row.sku_id;
  END IF;

  UPDATE public.orders
  SET status = 'cancelled', cancelled_at = now(), updated_at = now()
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  PERFORM public._post_points_delta(
    v_uid, v_row.points_amount, 'points_redeem_refund',
    '取消积分兑换，退回积分（单号 ' || v_row.out_trade_no || '）',
    'points_redeem_refund:' || v_row.id::text,
    'order', v_row.id, NULL
  );

  RETURN v_row;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.user_cancel_points_order(text, uuid) TO authenticated, anon, service_role;