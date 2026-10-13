-- ═══════════════════════════════════════════════════════════════════
-- 平台收款订单的微信自动退款：账本表 + 预约/落账（幂等）
-- 与商户退款对称，但平台只有一套商户号（平台微信支付配置），退款凭证按当前配置取，
-- 不设不可变凭证快照；每条退款记进账本，谁退的、退多少、微信退没退成功都有据可查。
-- 加锁顺序与商户退款一致：先锁 orders 行，再锁 platform_wechat_refunds 行。
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.platform_wechat_refunds (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL UNIQUE REFERENCES public.orders(id) ON DELETE RESTRICT,
  out_trade_no text NOT NULL UNIQUE,
  out_refund_no text NOT NULL UNIQUE,
  transaction_id text NOT NULL DEFAULT '',
  refund_amount_cents integer NOT NULL CHECK (refund_amount_cents > 0),
  total_amount_cents integer NOT NULL CHECK (total_amount_cents > 0),
  reason text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'success', 'closed', 'abnormal', 'failed')),
  wechat_refund_id text NOT NULL DEFAULT '',
  failure_summary text NOT NULL DEFAULT '',
  submit_lease_until timestamptz,
  submitted_at timestamptz,
  succeeded_at timestamptz,
  requested_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  requested_by_name text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pwfr_full_refund_only CHECK (refund_amount_cents = total_amount_cents)
);

CREATE INDEX IF NOT EXISTS idx_pwfr_inflight
  ON public.platform_wechat_refunds (status, updated_at DESC)
  WHERE status IN ('pending', 'processing');

CREATE TABLE IF NOT EXISTS public.platform_wechat_refund_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  refund_id uuid NOT NULL REFERENCES public.platform_wechat_refunds(id) ON DELETE CASCADE,
  source text NOT NULL CHECK (source IN ('request', 'query', 'notify')),
  event_key text NOT NULL,
  refund_status text NOT NULL DEFAULT '',
  wechat_refund_id text NOT NULL DEFAULT '',
  summary text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pwfre_event_uidx UNIQUE (refund_id, source, event_key)
);

CREATE INDEX IF NOT EXISTS idx_pwfre_refund_created
  ON public.platform_wechat_refund_events (refund_id, created_at DESC);

ALTER TABLE public.platform_wechat_refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_wechat_refund_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.platform_wechat_refunds FROM PUBLIC;
REVOKE ALL ON TABLE public.platform_wechat_refunds FROM anon;
REVOKE ALL ON TABLE public.platform_wechat_refunds FROM authenticated;
REVOKE ALL ON TABLE public.platform_wechat_refund_events FROM PUBLIC;
REVOKE ALL ON TABLE public.platform_wechat_refund_events FROM anon;
REVOKE ALL ON TABLE public.platform_wechat_refund_events FROM authenticated;

-- ═══════════════════════════════════════════════════════════════════
-- 预约平台全额退款（占位 + 租约）。只允许平台管理员发起，只退「收进平台商户号」的
-- 小程序微信支付单；支付宝/托管支付的单在这里拿不到支付快照，会直接拒绝。
-- ═══════════════════════════════════════════════════════════════════
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

  IF v_actor IS NULL OR v_actor.is_disabled OR v_actor.role <> 'admin' THEN
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

-- ═══════════════════════════════════════════════════════════════════
-- 落账平台退款结果。request / query / notify 三个来源都走这里，幂等落点与商户退款一致。
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.apply_platform_wechat_refund_result(
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
  v_refund public.platform_wechat_refunds;
  v_next text;
  v_raw text := upper(COALESCE(btrim(p_refund_status), ''));
  v_inserted uuid;
  v_summary text := left(COALESCE(p_summary, ''), 300);
BEGIN
  IF p_source NOT IN ('request', 'query', 'notify') THEN
    RAISE EXCEPTION 'invalid refund event source: %', p_source USING ERRCODE = '22023';
  END IF;

  SELECT order_id INTO v_order_id FROM public.platform_wechat_refunds
  WHERE out_refund_no = p_out_refund_no;
  IF v_order_id IS NULL THEN
    RAISE EXCEPTION '退款记录不存在' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = v_order_id FOR UPDATE;
  SELECT * INTO v_refund FROM public.platform_wechat_refunds
  WHERE out_refund_no = p_out_refund_no FOR UPDATE;

  INSERT INTO public.platform_wechat_refund_events (
    refund_id, source, event_key, refund_status, wechat_refund_id, summary
  ) VALUES (
    v_refund.id, p_source, COALESCE(NULLIF(btrim(p_event_key), ''), 'default'),
    v_raw, COALESCE(p_wechat_refund_id, ''), v_summary
  )
  ON CONFLICT (refund_id, source, event_key) DO NOTHING
  RETURNING id INTO v_inserted;

  IF v_inserted IS NULL THEN
    RETURN jsonb_build_object(
      'applied', false, 'status', v_refund.status, 'order_status', v_order.status
    );
  END IF;

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

  UPDATE public.platform_wechat_refunds SET
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
      COALESCE(NULLIF(v_refund.reason, ''), '平台发起全额退款')
    );
  ELSIF v_next = 'abnormal' THEN
    UPDATE public.orders SET
      manual_refund_required = true,
      refund_reason = CASE WHEN refund_reason = '' THEN '微信退款异常，需商户平台人工处理'
        ELSE refund_reason END,
      updated_at = now()
    WHERE id = v_order.id;
  ELSIF v_next IN ('closed', 'failed') AND v_order.status = 'refunding' THEN
    UPDATE public.orders SET status = 'paid', updated_at = now() WHERE id = v_order.id;
  END IF;

  RETURN jsonb_build_object('applied', true, 'status', v_next);
END;
$$;

REVOKE ALL ON FUNCTION public.reserve_platform_wechat_full_refund(text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reserve_platform_wechat_full_refund(text, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.reserve_platform_wechat_full_refund(text, uuid, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.apply_platform_wechat_refund_result(text, text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.apply_platform_wechat_refund_result(text, text, text, text, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.apply_platform_wechat_refund_result(text, text, text, text, text, text) FROM authenticated;

GRANT EXECUTE ON FUNCTION public.reserve_platform_wechat_full_refund(text, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.apply_platform_wechat_refund_result(text, text, text, text, text, text) TO service_role;