-- ============================================================================
-- 商城履约 + 积分体系 批次 3c：发货 / 收货 / 评价 / 退货双通道审批
-- ============================================================================

-- ─────────────────────────────────────────────────────────────
-- 3c-0) 共用小工具
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._auto_receive_days()
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_days integer;
BEGIN
  v_days := public._points_rule_amount('shop_auto_receive_days');
  -- 配置为 0 或异常大都回落到 7 天：0 会让订单永远无法自动收货
  IF v_days <= 0 OR v_days > 60 THEN
    RETURN 7;
  END IF;
  RETURN v_days;
END;
$$;


CREATE OR REPLACE FUNCTION public._validate_image_array(p_images jsonb, p_max integer)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_item jsonb;
BEGIN
  IF p_images IS NULL OR jsonb_typeof(p_images) = 'null' THEN
    RETURN '[]'::jsonb;
  END IF;
  IF jsonb_typeof(p_images) <> 'array' THEN
    RAISE EXCEPTION '图片格式不正确' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_images) > p_max THEN
    RAISE EXCEPTION '最多上传 % 张图片', p_max USING ERRCODE = '22023';
  END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_images) LOOP
    IF jsonb_typeof(v_item) <> 'string'
       OR char_length(v_item #>> '{}') = 0
       OR char_length(v_item #>> '{}') > 500 THEN
      RAISE EXCEPTION '图片地址不正确' USING ERRCODE = '22023';
    END IF;
  END LOOP;
  RETURN p_images;
END;
$$;


-- ─────────────────────────────────────────────────────────────
-- 3c-1) 商户发货
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manager_ship_order(
  p_out_trade_no text,
  p_carrier_name text,
  p_tracking_no  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_scope   jsonb := public._resolve_manager_scope(auth.uid());
  v_caller  uuid  := (v_scope->>'caller_id')::uuid;
  v_root    uuid  := (v_scope->>'root_id')::uuid;
  v_is_root boolean := (v_scope->>'is_root')::boolean;
  v_owners  uuid[] := public._manager_visible_owner_ids(v_caller, v_root, v_is_root);
  v_order   public.orders;
  v_carrier text;
  v_no      text;
BEGIN
  v_carrier := btrim(COALESCE(p_carrier_name, ''));
  v_no      := btrim(COALESCE(p_tracking_no, ''));
  IF v_carrier = '' OR char_length(v_carrier) > 40 THEN
    RAISE EXCEPTION '请填写物流公司（40 字以内）' USING ERRCODE = '22023';
  END IF;
  IF v_no = '' OR char_length(v_no) > 64 THEN
    RAISE EXCEPTION '请填写物流单号（64 位以内）' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_order FROM public.orders
  WHERE out_trade_no = p_out_trade_no FOR UPDATE;

  -- 三道显式判定：行不存在、发货方为空（平台自营）、发货方不在可见范围。
  -- 中间那道不能省，否则 NULL = ANY(...) 会返回 NULL 静默放行。
  IF v_order.id IS NULL
     OR v_order.fulfillment_manager_id_snapshot IS NULL
     OR NOT (v_order.fulfillment_manager_id_snapshot = ANY(v_owners)) THEN
    RAISE EXCEPTION '订单不存在或不属于你' USING ERRCODE = '42501';
  END IF;

  IF v_order.status IS DISTINCT FROM 'paid' THEN
    RAISE EXCEPTION '只有已支付的订单可以发货' USING ERRCODE = '22023';
  END IF;
  IF v_order.requires_shipping_snapshot IS DISTINCT FROM true THEN
    RAISE EXCEPTION '该订单无需发货' USING ERRCODE = '22023';
  END IF;
  IF v_order.fulfillment_status IS DISTINCT FROM 'pending_ship' THEN
    RAISE EXCEPTION '该订单当前不是待发货状态' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.order_return_requests r
    WHERE r.order_id = v_order.id AND r.status IN ('pending', 'approved')
  ) THEN
    RAISE EXCEPTION '该订单有正在处理的退货申请，请先处理申请' USING ERRCODE = '22023';
  END IF;

  UPDATE public.orders
  SET fulfillment_status = 'shipped',
      carrier_name       = v_carrier,
      tracking_no        = v_no,
      shipped_at         = now(),
      auto_receive_at    = now() + make_interval(days => public._auto_receive_days()),
      updated_at         = now()
  WHERE id = v_order.id
  RETURNING * INTO v_order;

  RETURN jsonb_build_object(
    'out_trade_no', v_order.out_trade_no,
    'fulfillment_status', v_order.fulfillment_status,
    'carrier_name', v_order.carrier_name,
    'tracking_no', v_order.tracking_no,
    'shipped_at', v_order.shipped_at,
    'auto_receive_at', v_order.auto_receive_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.manager_ship_order(text, text, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 3c-2) 平台发货（平台自营订单，即无归属商户的订单）
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_ship_order(
  p_out_trade_no text,
  p_carrier_name text,
  p_tracking_no  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_order   public.orders;
  v_carrier text;
  v_no      text;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '只有平台管理员可以在后台发货' USING ERRCODE = '42501';
  END IF;

  v_carrier := btrim(COALESCE(p_carrier_name, ''));
  v_no      := btrim(COALESCE(p_tracking_no, ''));
  IF v_carrier = '' OR char_length(v_carrier) > 40 THEN
    RAISE EXCEPTION '请填写物流公司（40 字以内）' USING ERRCODE = '22023';
  END IF;
  IF v_no = '' OR char_length(v_no) > 64 THEN
    RAISE EXCEPTION '请填写物流单号（64 位以内）' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_order FROM public.orders
  WHERE out_trade_no = p_out_trade_no FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF v_order.fulfillment_manager_id_snapshot IS NOT NULL THEN
    RAISE EXCEPTION '该订单由商户负责发货，平台不代为发货' USING ERRCODE = '22023';
  END IF;
  IF v_order.status IS DISTINCT FROM 'paid' THEN
    RAISE EXCEPTION '只有已支付的订单可以发货' USING ERRCODE = '22023';
  END IF;
  IF v_order.requires_shipping_snapshot IS DISTINCT FROM true THEN
    RAISE EXCEPTION '该订单无需发货' USING ERRCODE = '22023';
  END IF;
  IF v_order.fulfillment_status IS DISTINCT FROM 'pending_ship' THEN
    RAISE EXCEPTION '该订单当前不是待发货状态' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.order_return_requests r
    WHERE r.order_id = v_order.id AND r.status IN ('pending', 'approved')
  ) THEN
    RAISE EXCEPTION '该订单有正在处理的退货申请，请先处理申请' USING ERRCODE = '22023';
  END IF;

  UPDATE public.orders
  SET fulfillment_status = 'shipped',
      carrier_name       = v_carrier,
      tracking_no        = v_no,
      shipped_at         = now(),
      auto_receive_at    = now() + make_interval(days => public._auto_receive_days()),
      updated_at         = now()
  WHERE id = v_order.id
  RETURNING * INTO v_order;

  RETURN jsonb_build_object(
    'out_trade_no', v_order.out_trade_no,
    'fulfillment_status', v_order.fulfillment_status,
    'carrier_name', v_order.carrier_name,
    'tracking_no', v_order.tracking_no,
    'shipped_at', v_order.shipped_at,
    'auto_receive_at', v_order.auto_receive_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_ship_order(text, text, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 3c-3) 用户确认收货
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.user_confirm_receipt(p_out_trade_no text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
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
  IF v_order.fulfillment_status IN ('received', 'completed') THEN
    -- 幂等：自动收货已经落库过，重复点击不报错
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
$$;

GRANT EXECUTE ON FUNCTION public.user_confirm_receipt(text) TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 3c-4) 用户提交评价（阶段一只有本人与商户可见，不公开展示）
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.user_submit_order_review(
  p_out_trade_no text,
  p_rating       integer,
  p_content      text  DEFAULT '',
  p_images       jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
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

  -- 实体订单评价后收尾为已完成；虚拟订单必须保持 not_required（有约束）
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
$$;

GRANT EXECUTE ON FUNCTION public.user_submit_order_review(text, integer, text, jsonb) TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 3c-5) 用户提交退货退款申请
--   handler_scope 完全由服务端按「这笔钱实际收进谁的商户号」判定，
--   绝不接受客户端传入，否则用户可以把平台单伪造成商户单去走自动退款。
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.user_create_return_request(
  p_out_trade_no text,
  p_reason_code  text,
  p_reason_text  text,
  p_images       jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
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

  -- 积分兑换单统一由平台处理，退回积分而不是退钱
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
$$;

GRANT EXECUTE ON FUNCTION public.user_create_return_request(text, text, text, jsonb) TO authenticated;


CREATE OR REPLACE FUNCTION public.user_cancel_return_request(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.order_return_requests;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  UPDATE public.order_return_requests
  SET status = 'cancelled', updated_at = now()
  WHERE id = p_request_id AND user_id = v_uid AND status = 'pending'
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION '该申请已被处理，无法撤回' USING ERRCODE = '22023';
  END IF;

  RETURN to_jsonb(v_row);
END;
$$;

GRANT EXECUTE ON FUNCTION public.user_cancel_return_request(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 3c-6) 商户审批退货（仅商户收款的现金单）
--   本函数只负责「记录决定」，真正的退款由 Edge Function 接着走
--   现有的 reserve → 微信 链路。两步分离是为了不把外部网络调用
--   塞进数据库事务里。
--   auth.uid() 非空时一律以它为准，忽略传入的 p_operator_id，
--   避免被伪造成他人身份。
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manager_decide_return_request(
  p_request_id  uuid,
  p_approve     boolean,
  p_note        text DEFAULT NULL,
  p_operator_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor   uuid := COALESCE(auth.uid(), p_operator_id);
  v_scope   jsonb;
  v_root    uuid;
  v_is_root boolean;
  v_req     public.order_return_requests;
  v_note    text;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  v_scope   := public._resolve_manager_scope(v_actor);
  v_root    := (v_scope->>'root_id')::uuid;
  v_is_root := (v_scope->>'is_root')::boolean;

  IF v_root IS NULL OR v_is_root IS DISTINCT FROM true THEN
    RAISE EXCEPTION '只有企业负责人可以处理退货申请' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_req FROM public.order_return_requests
  WHERE id = p_request_id FOR UPDATE;

  IF v_req.id IS NULL
     OR v_req.handler_scope IS DISTINCT FROM 'merchant'
     OR v_req.handler_manager_id IS NULL
     OR v_req.handler_manager_id IS DISTINCT FROM v_root THEN
    RAISE EXCEPTION '该退货申请不属于你处理' USING ERRCODE = '42501';
  END IF;
  IF v_req.status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION '该申请已处理过' USING ERRCODE = '22023';
  END IF;

  v_note := NULLIF(btrim(COALESCE(p_note, '')), '');

  IF COALESCE(p_approve, false) THEN
    UPDATE public.order_return_requests
    SET status = 'approved', decided_by = v_actor, decided_at = now(),
        decision_note = v_note, updated_at = now()
    WHERE id = v_req.id
    RETURNING * INTO v_req;
  ELSE
    IF v_note IS NULL THEN
      RAISE EXCEPTION '驳回时必须填写原因，用户会看到这句话' USING ERRCODE = '22023';
    END IF;
    UPDATE public.order_return_requests
    SET status = 'rejected', decided_by = v_actor, decided_at = now(),
        decision_note = v_note, updated_at = now()
    WHERE id = v_req.id
    RETURNING * INTO v_req;
  END IF;

  RETURN to_jsonb(v_req);
END;
$$;

GRANT EXECUTE ON FUNCTION public.manager_decide_return_request(uuid, boolean, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_decide_return_request(uuid, boolean, text, uuid) TO service_role;


-- ─────────────────────────────────────────────────────────────
-- 3c-7) 平台审批退货（平台收款的现金单 + 全部积分单）
--   现金单：平台同意后仍需人工到支付平台后台执行退款，
--           订单只能由网关回调改成 refunded，本函数绝不代写。
--   积分单：没有任何现金，平台同意即当场退回积分并把订单收尾为已取消。
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_decide_return_request(
  p_request_id uuid,
  p_approve    boolean,
  p_note       text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_req   public.order_return_requests;
  v_order public.orders;
  v_note  text;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '只有平台管理员可以处理平台退货申请' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_req FROM public.order_return_requests
  WHERE id = p_request_id FOR UPDATE;

  IF v_req.id IS NULL OR v_req.handler_scope IS DISTINCT FROM 'platform' THEN
    RAISE EXCEPTION '该退货申请由商户处理，平台不介入' USING ERRCODE = '42501';
  END IF;
  IF v_req.status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION '该申请已处理过' USING ERRCODE = '22023';
  END IF;

  v_note := NULLIF(btrim(COALESCE(p_note, '')), '');

  IF NOT COALESCE(p_approve, false) THEN
    IF v_note IS NULL THEN
      RAISE EXCEPTION '驳回时必须填写原因，用户会看到这句话' USING ERRCODE = '22023';
    END IF;
    UPDATE public.order_return_requests
    SET status = 'rejected', decided_by = v_uid, decided_at = now(),
        decision_note = v_note, updated_at = now()
    WHERE id = v_req.id
    RETURNING * INTO v_req;
    RETURN to_jsonb(v_req);
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = v_req.order_id FOR UPDATE;

  IF v_order.pay_mode = 'points' THEN
    -- 积分单：还原库存、退回积分、订单收尾
    IF v_order.sku_id IS NOT NULL THEN
      PERFORM 1 FROM public.product_skus WHERE id = v_order.sku_id FOR UPDATE;
      UPDATE public.product_skus
      SET stock = stock + v_order.quantity, updated_at = now()
      WHERE id = v_order.sku_id;
    END IF;

    UPDATE public.orders
    SET status = 'cancelled', cancelled_at = now(), updated_at = now()
    WHERE id = v_order.id;

    PERFORM public._post_points_delta(
      v_order.user_id, v_order.points_amount, 'points_redeem_refund',
      '退货通过，退回兑换积分（单号 ' || v_order.out_trade_no || '）',
      'points_redeem_refund:' || v_order.id::text,
      'order', v_order.id, v_uid
    );

    UPDATE public.order_return_requests
    SET status = 'refunded', decided_by = v_uid, decided_at = now(),
        decision_note = v_note, updated_at = now()
    WHERE id = v_req.id
    RETURNING * INTO v_req;
  ELSE
    -- 现金单：只记录同意，退款仍需人工到支付平台后台执行。
    -- 订单状态由支付网关回调驱动，这里不改 orders.status。
    UPDATE public.order_return_requests
    SET status = 'approved', decided_by = v_uid, decided_at = now(),
        decision_note = v_note, updated_at = now()
    WHERE id = v_req.id
    RETURNING * INTO v_req;
  END IF;

  RETURN to_jsonb(v_req);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_decide_return_request(uuid, boolean, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 3c-8) 订单退款完成时，把已同意的退货申请同步为已退款
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._sync_return_request_on_refund()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status = 'refunded' AND OLD.status IS DISTINCT FROM 'refunded' THEN
    UPDATE public.order_return_requests
    SET status = 'refunded', updated_at = now()
    WHERE order_id = NEW.id AND status IN ('pending', 'approved');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS orders_sync_return_request ON public.orders;
CREATE TRIGGER orders_sync_return_request
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public._sync_return_request_on_refund();


-- ─────────────────────────────────────────────────────────────
-- 3c-9) 积分兑换单永不进现金退款状态机
--   做成表级触发器而不是改 reserve_manager_wechat_full_refund 的函数体：
--   reserve 的第一步就是把订单置为 refunding，触发器会在那一刻就用中文拒绝，
--   也就是在任何微信网络调用之前，且同时覆盖所有其他退款路径。
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._reject_points_order_cash_refund()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.pay_mode = 'points'
     AND NEW.status IN ('refunding', 'refunded')
     AND OLD.status IS DISTINCT FROM NEW.status THEN
    RAISE EXCEPTION '积分兑换单没有现金支付，不能走退款流程；请使用取消兑换或退货申请退回积分'
      USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS orders_reject_points_cash_refund ON public.orders;
CREATE TRIGGER orders_reject_points_cash_refund
  BEFORE UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public._reject_points_order_cash_refund();