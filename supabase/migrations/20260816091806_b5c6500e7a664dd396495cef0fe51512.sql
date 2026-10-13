-- 修复权限闸门：profiles.role 可能为 NULL，`role <> 'admin'` 遇 NULL 时整个条件为 NULL，
-- IF 分支不会进入，导致 role 为空的账号绕过管理员校验。改用 IS DISTINCT FROM + 显式判空 + 对 is_disabled 兜底。

CREATE OR REPLACE FUNCTION public.reserve_platform_wechat_full_refund(
  p_out_trade_no text,
  p_actor_id uuid,
  p_reason text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_order public.orders;
  v_pay public.wechat_miniapp_pay_orders;
  v_refund public.platform_wechat_refunds;
  v_actor record;
  v_reason text := left(COALESCE(btrim(p_reason), ''), 80);
  v_out_refund_no text;
  v_refund_id uuid;
  v_lease timestamptz := now() + interval '2 minutes';
BEGIN
  SELECT id, role, is_disabled, COALESCE(nickname, '') AS nickname
  INTO v_actor
  FROM public.profiles WHERE id = p_actor_id;

  IF v_actor.id IS NULL OR COALESCE(v_actor.is_disabled, false) OR v_actor.role IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION '只有平台管理员可以发起平台退款' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_order FROM public.orders
  WHERE out_trade_no = p_out_trade_no FOR UPDATE;
  IF v_order IS NULL THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_pay FROM public.wechat_miniapp_pay_orders WHERE order_id = v_order.id;
  IF v_pay.id IS NULL OR v_pay.payee_type <> 'platform' THEN
    RAISE EXCEPTION '这笔钱不是收进平台微信商户号，无法自动退款，请到支付平台人工处理' USING ERRCODE = '42501';
  END IF;
  IF v_pay.wechat_transaction_id = '' THEN
    RAISE EXCEPTION '还没拿到微信支付单号，请稍后再试' USING ERRCODE = '22023';
  END IF;

  IF v_order.status = 'refunded' THEN
    RAISE EXCEPTION '该订单已完成退款' USING ERRCODE = '22023';
  END IF;
  IF v_order.status <> 'paid' AND v_order.status <> 'refunding' THEN
    RAISE EXCEPTION '只有已支付的订单可以退款' USING ERRCODE = '22023';
  END IF;
  IF v_order.paid_at IS NULL OR v_order.paid_at < now() - interval '365 days' THEN
    RAISE EXCEPTION '超过一年的订单微信不再支持退款，请通过微信支付商户平台人工处理'
      USING ERRCODE = '22023';
  END IF;

  v_out_refund_no := 'PRF' || replace(v_order.id::text, '-', '');

  SELECT * INTO v_refund FROM public.platform_wechat_refunds
  WHERE order_id = v_order.id FOR UPDATE;

  IF v_refund.id IS NOT NULL THEN
    IF v_refund.status = 'success' THEN
      RAISE EXCEPTION '该订单已完成退款' USING ERRCODE = '22023';
    END IF;
    IF v_refund.status = 'abnormal' THEN
      RAISE EXCEPTION '这笔退款微信要求在商户平台人工处理，请勿重复提交' USING ERRCODE = '22023';
    END IF;
    IF v_refund.status IN ('pending', 'processing')
       AND v_refund.submit_lease_until IS NOT NULL
       AND v_refund.submit_lease_until > now() THEN
      RAISE EXCEPTION '退款正在处理中，请稍后刷新查看结果' USING ERRCODE = '55P03';
    END IF;

    UPDATE public.platform_wechat_refunds SET
      status = 'pending',
      reason = CASE WHEN v_reason = '' THEN reason ELSE v_reason END,
      failure_summary = '',
      submit_lease_until = v_lease,
      submitted_at = now(),
      requested_by = v_actor.id,
      requested_by_name = v_actor.nickname,
      updated_at = now()
    WHERE id = v_refund.id
    RETURNING id INTO v_refund_id;
  ELSE
    INSERT INTO public.platform_wechat_refunds (
      order_id, out_trade_no, out_refund_no, transaction_id,
      refund_amount_cents, total_amount_cents, reason,
      status, submit_lease_until, submitted_at,
      requested_by, requested_by_name
    ) VALUES (
      v_order.id, v_order.out_trade_no, v_out_refund_no, v_pay.wechat_transaction_id,
      v_order.total_amount_cents, v_order.total_amount_cents, v_reason,
      'pending', v_lease, now(),
      v_actor.id, v_actor.nickname
    )
    RETURNING id INTO v_refund_id;
  END IF;

  IF v_order.status = 'paid' THEN
    UPDATE public.orders SET status = 'refunding', updated_at = now()
    WHERE id = v_order.id;
  END IF;

  INSERT INTO public.operation_logs (
    user_id, action, detail, module, metadata, enterprise_root_id, actor_name_snapshot
  ) VALUES (
    v_actor.id,
    '发起平台微信退款',
    '订单 ' || v_order.out_trade_no || ' 全额退款 '
      || to_char(v_order.total_amount_cents / 100.0, 'FM999999990.00') || ' 元',
    'shop_refund',
    jsonb_build_object(
      'out_trade_no', v_order.out_trade_no,
      'out_refund_no', v_out_refund_no,
      'refund_amount_cents', v_order.total_amount_cents,
      'mch_id', v_pay.mch_id
    ),
    v_actor.id,
    v_actor.nickname
  );

  RETURN jsonb_build_object(
    'refund_id', v_refund_id,
    'out_refund_no', v_out_refund_no,
    'out_trade_no', v_order.out_trade_no,
    'transaction_id', v_pay.wechat_transaction_id,
    'refund_amount_cents', v_order.total_amount_cents,
    'total_amount_cents', v_order.total_amount_cents,
    'reason', COALESCE(NULLIF(v_reason, ''), '平台发起全额退款')
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_approve_return_for_platform_refund(
  p_request_id uuid,
  p_operator_id uuid,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_op record;
  v_req public.order_return_requests;
  v_order public.orders;
  v_note text;
BEGIN
  SELECT id, role, is_disabled, COALESCE(nickname, '') AS nickname
  INTO v_op FROM public.profiles WHERE id = p_operator_id;
  IF v_op.id IS NULL OR COALESCE(v_op.is_disabled, false) OR v_op.role IS DISTINCT FROM 'admin' THEN
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

  SELECT * INTO v_order FROM public.orders WHERE id = v_req.order_id FOR UPDATE;
  IF v_order.pay_mode = 'points' THEN
    RAISE EXCEPTION '积分兑换单请走积分退回，不要走现金退款' USING ERRCODE = '22023';
  END IF;

  UPDATE public.order_return_requests
  SET status = 'approved', decided_by = v_op.id, decided_at = now(),
      decision_note = v_note, updated_at = now()
  WHERE id = v_req.id
  RETURNING * INTO v_req;

  RETURN jsonb_build_object(
    'out_trade_no', v_order.out_trade_no,
    'pay_mode', v_order.pay_mode
  );
END;
$$;