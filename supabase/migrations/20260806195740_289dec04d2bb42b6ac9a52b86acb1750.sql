-- ═══════════════════════════════════════════════════════════════════
-- 微信退款：预约（占位 + 租约）与结果落账（幂等）
--
-- 加锁顺序在两个函数里保持一致：先锁 orders 行，再锁 wechat_miniapp_refunds 行。
-- 反向加锁会与另一个函数形成环，并发退款时直接死锁。
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.reserve_manager_wechat_full_refund(
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
  v_refund public.wechat_miniapp_refunds;
  v_actor record;
  v_reason text := left(COALESCE(btrim(p_reason), ''), 80);
  v_out_refund_no text;
  v_refund_id uuid;
  v_lease timestamptz := now() + interval '2 minutes';
BEGIN
  SELECT id, role, parent_manager_id, is_disabled, COALESCE(nickname, '') AS nickname
  INTO v_actor
  FROM public.profiles WHERE id = p_actor_id;

  IF v_actor IS NULL OR v_actor.is_disabled OR v_actor.role <> 'manager' THEN
    RAISE EXCEPTION '账号无权发起退款' USING ERRCODE = '42501';
  END IF;
  IF v_actor.parent_manager_id IS NOT NULL THEN
    RAISE EXCEPTION '只有企业负责人可以发起退款' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_order FROM public.orders
  WHERE out_trade_no = p_out_trade_no FOR UPDATE;
  IF v_order IS NULL THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_pay FROM public.wechat_miniapp_pay_orders WHERE order_id = v_order.id;
  IF v_pay.id IS NULL OR v_pay.payee_type <> 'manager' OR v_pay.credential_version_id IS NULL THEN
    RAISE EXCEPTION '这笔钱不是收进你的商户号，请联系平台处理退款' USING ERRCODE = '42501';
  END IF;
  IF v_pay.payee_manager_id IS DISTINCT FROM v_actor.id THEN
    RAISE EXCEPTION '这笔钱不是收进你的商户号，请联系平台处理退款' USING ERRCODE = '42501';
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

  -- 退款单号按订单 id 派生：同一笔订单反复提交拿到的永远是同一个单号，
  -- 微信侧天然幂等，网络抖动重发也不会退两次钱。
  v_out_refund_no := 'RF' || replace(v_order.id::text, '-', '');

  SELECT * INTO v_refund FROM public.wechat_miniapp_refunds
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

    UPDATE public.wechat_miniapp_refunds SET
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
    INSERT INTO public.wechat_miniapp_refunds (
      order_id, out_trade_no, out_refund_no,
      pay_order_id, pay_account_id, credential_version_id, payee_manager_id,
      refund_amount_cents, total_amount_cents, reason,
      status, submit_lease_until, submitted_at,
      requested_by, requested_by_name
    ) VALUES (
      v_order.id, v_order.out_trade_no, v_out_refund_no,
      v_pay.id, v_pay.pay_account_id, v_pay.credential_version_id, v_pay.payee_manager_id,
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
    '发起微信退款',
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
    'credential_version_id', v_pay.credential_version_id,
    'reason', COALESCE(NULLIF(v_reason, ''), '商户发起全额退款')
  );
END;
$$;

/**
 * 落账退款结果。request / query / notify 三个来源都走这里。
 * 同一来源同一事件只生效一次（事件表的唯一约束就是幂等落点）；
 * 已经成功的退款不会被任何后到的消息降级。
 */
CREATE OR REPLACE FUNCTION public.apply_manager_wechat_refund_result(
  p_out_refund_no text,
  p_source text,
  p_event_key text,
  p_refund_status text,
  p_wechat_refund_id text DEFAULT '',
  p_summary text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_order_id uuid;
  v_order public.orders;
  v_refund public.wechat_miniapp_refunds;
  v_next text;
  v_raw text := upper(COALESCE(btrim(p_refund_status), ''));
  v_inserted uuid;
  v_summary text := left(COALESCE(p_summary, ''), 300);
BEGIN
  IF p_source NOT IN ('request', 'query', 'notify') THEN
    RAISE EXCEPTION 'invalid refund event source: %', p_source USING ERRCODE = '22023';
  END IF;

  SELECT order_id INTO v_order_id FROM public.wechat_miniapp_refunds
  WHERE out_refund_no = p_out_refund_no;
  IF v_order_id IS NULL THEN
    RAISE EXCEPTION '退款记录不存在' USING ERRCODE = '22023';
  END IF;

  -- 加锁顺序：orders → wechat_miniapp_refunds（与 reserve 一致，避免死锁）
  SELECT * INTO v_order FROM public.orders WHERE id = v_order_id FOR UPDATE;
  SELECT * INTO v_refund FROM public.wechat_miniapp_refunds
  WHERE out_refund_no = p_out_refund_no FOR UPDATE;

  INSERT INTO public.wechat_miniapp_refund_events (
    refund_id, source, event_key, refund_status, wechat_refund_id, summary
  ) VALUES (
    v_refund.id, p_source, COALESCE(NULLIF(btrim(p_event_key), ''), 'default'),
    v_raw, COALESCE(p_wechat_refund_id, ''), v_summary
  )
  ON CONFLICT (refund_id, source, event_key) DO NOTHING
  RETURNING id INTO v_inserted;

  -- 重复推送：不再改任何状态，直接回当前结论
  IF v_inserted IS NULL THEN
    RETURN jsonb_build_object(
      'applied', false, 'status', v_refund.status, 'order_status', v_order.status
    );
  END IF;

  -- 已成功的退款是终态，任何后到的消息都不能把它拉回去
  IF v_refund.status = 'success' THEN
    RETURN jsonb_build_object(
      'applied', false, 'status', 'success', 'order_status', v_order.status
    );
  END IF;

  v_next := CASE v_raw
    WHEN 'SUCCESS' THEN 'success'
    WHEN 'CLOSED' THEN 'closed'
    WHEN 'ABNORMAL' THEN 'abnormal'
    WHEN 'PROCESSING' THEN 'processing'
    ELSE 'failed'
  END;

  UPDATE public.wechat_miniapp_refunds SET
    status = v_next,
    wechat_refund_id = CASE WHEN COALESCE(p_wechat_refund_id, '') <> ''
      THEN p_wechat_refund_id ELSE wechat_refund_id END,
    failure_summary = CASE WHEN v_next IN ('closed', 'abnormal', 'failed')
      THEN v_summary ELSE '' END,
    succeeded_at = CASE WHEN v_next = 'success' THEN now() ELSE succeeded_at END,
    submit_lease_until = CASE WHEN v_next = 'processing' THEN submit_lease_until ELSE NULL END,
    updated_at = now()
  WHERE id = v_refund.id;

  IF v_next = 'success' THEN
    PERFORM public.mark_order_refunded_from_gateway(
      v_refund.out_trade_no,
      v_refund.refund_amount_cents,
      COALESCE(NULLIF(v_refund.reason, ''), '商户发起全额退款')
    );
  ELSIF v_next = 'abnormal' THEN
    -- 微信要求在商户平台人工处理：订单保持退款中，同时标出来让平台看得到
    UPDATE public.orders SET
      manual_refund_required = true,
      refund_reason = CASE WHEN refund_reason = '' THEN '微信退款异常，需商户平台人工处理'
        ELSE refund_reason END,
      updated_at = now()
    WHERE id = v_order.id;
  ELSIF v_next IN ('closed', 'failed') AND v_order.status = 'refunding' THEN
    -- 退款没成，钱还在商户账上：把订单放回已支付，商户可以再试
    UPDATE public.orders SET status = 'paid', updated_at = now() WHERE id = v_order.id;
  END IF;

  RETURN jsonb_build_object('applied', true, 'status', v_next);
END;
$$;

-- 退款真的到账后，「异常待退款」这个人工待办就该被清掉，否则平台后台永远挂着一条假待办
CREATE OR REPLACE FUNCTION public.mark_order_refunded_from_gateway(
  p_out_trade_no text,
  p_refund_amount integer,
  p_reason text
)
RETURNS orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_order orders;
BEGIN
  SELECT * INTO v_order
    FROM orders
    WHERE out_trade_no = p_out_trade_no
    FOR UPDATE;

  IF NOT FOUND THEN
    -- 静默：log + 返 NULL 让回调端返 success
    RAISE NOTICE 'refund notify for missing order: %', p_out_trade_no;
    RETURN NULL;
  END IF;

  -- 幂等：已经 refunded 直接返回
  IF v_order.status = 'refunded' THEN
    RETURN v_order;
  END IF;

  -- 仅 paid / closed / refunding 允许标 refunded
  IF v_order.status NOT IN ('paid','closed','refunding') THEN
    RAISE NOTICE 'refund notify ignored, order status=%', v_order.status;
    RETURN v_order;
  END IF;

  UPDATE orders
    SET status = 'refunded',
        refunded_at = NOW(),
        refund_amount_cents = p_refund_amount,
        refund_reason = COALESCE(p_reason, ''),
        manual_refund_required = false
    WHERE id = v_order.id
    RETURNING * INTO v_order;

  RETURN v_order;
END;
$function$;

REVOKE ALL ON FUNCTION public.reserve_manager_wechat_full_refund(text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reserve_manager_wechat_full_refund(text, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.reserve_manager_wechat_full_refund(text, uuid, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.apply_manager_wechat_refund_result(text, text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.apply_manager_wechat_refund_result(text, text, text, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.apply_manager_wechat_refund_result(text, text, text, text, text, text) FROM authenticated;

GRANT EXECUTE ON FUNCTION public.reserve_manager_wechat_full_refund(text, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.apply_manager_wechat_refund_result(text, text, text, text, text, text) TO service_role;