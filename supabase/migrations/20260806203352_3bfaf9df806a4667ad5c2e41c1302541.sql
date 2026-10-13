-- ═══════════════════════════════════════════════════════════════════
-- 修复：manager_get_shop_order 的归属闸门被 NULL 静默绕过
--
-- 原写法 IF NOT (owner_manager_id_snapshot = ANY(v_owners))：
-- 平台自营订单的 owner_manager_id_snapshot 是 NULL，NULL = ANY(...) 结果是 NULL 而不是
-- false，NOT NULL 仍是 NULL，plpgsql 的 IF 遇到 NULL 不进分支 —— 闸门等于没有。
-- 结果任何商户都能读到平台自营订单的顾客信息（已付款时还是未脱敏的姓名/手机/地址）。
--
-- 列表函数 manager_list_shop_orders 把同样的条件写在 WHERE 里，NULL 在 WHERE 中按假处理，
-- 所以列表没有泄露，只有详情函数有。这里连同 record IS NULL 这种脆弱写法一起改成显式判空。
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.manager_get_shop_order(p_out_trade_no text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_scope jsonb := public._resolve_manager_scope(auth.uid());
  v_caller uuid := (v_scope->>'caller_id')::uuid;
  v_root uuid := (v_scope->>'root_id')::uuid;
  v_is_root boolean := (v_scope->>'is_root')::boolean;
  v_owners uuid[] := public._manager_visible_owner_ids(v_caller, v_root, v_is_root);
  v_order public.orders;
  v_pay public.wechat_miniapp_pay_orders;
  v_refund public.wechat_miniapp_refunds;
  v_owner_name text := '';
  v_events jsonb := '[]'::jsonb;
  v_fulfillment_visible boolean;
  v_can_refund boolean := false;
  v_reason text := '';
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE out_trade_no = p_out_trade_no;

  -- 三道都必须显式写出来：行不存在、归属为空（平台自营）、归属不在可见范围内。
  -- 少写中间那一道就会被 NULL 的三值逻辑绕过。
  IF v_order.id IS NULL
     OR v_order.owner_manager_id_snapshot IS NULL
     OR NOT (v_order.owner_manager_id_snapshot = ANY(v_owners)) THEN
    RAISE EXCEPTION '订单不存在或不属于你' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(nickname, '') INTO v_owner_name
  FROM public.profiles WHERE id = v_order.owner_manager_id_snapshot;

  SELECT * INTO v_pay FROM public.wechat_miniapp_pay_orders WHERE order_id = v_order.id;
  SELECT * INTO v_refund FROM public.wechat_miniapp_refunds WHERE order_id = v_order.id;

  IF v_refund.id IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'source', e.source,
      'refund_status', e.refund_status,
      'summary', e.summary,
      'created_at', e.created_at
    ) ORDER BY e.created_at DESC), '[]'::jsonb)
    INTO v_events
    FROM public.wechat_miniapp_refund_events e
    WHERE e.refund_id = v_refund.id;
  END IF;

  v_fulfillment_visible := v_order.status IN ('paid', 'refunding', 'refunded', 'closed');

  -- 能不能发起退款：逐条判定并给出中文原因，界面直接展示这句话
  IF NOT v_is_root THEN
    v_reason := '只有企业负责人可以发起退款';
  ELSIF v_order.status = 'refunded' THEN
    v_reason := '该订单已完成退款';
  ELSIF v_order.status = 'refunding' THEN
    v_reason := '退款正在处理中，请稍后刷新查看结果';
  ELSIF v_order.status <> 'paid' THEN
    v_reason := '只有已支付的订单可以退款';
  ELSIF v_pay.id IS NULL
     OR COALESCE(v_pay.payee_type, '') <> 'manager'
     OR v_pay.credential_version_id IS NULL THEN
    v_reason := '这笔钱不是收进你的商户号，请联系平台处理退款';
  ELSIF v_pay.payee_manager_id IS DISTINCT FROM v_root THEN
    v_reason := '这笔钱不是收进你的商户号，请联系平台处理退款';
  ELSIF COALESCE(v_pay.wechat_transaction_id, '') = '' THEN
    v_reason := '还没拿到微信支付单号，请稍后再试';
  ELSIF v_order.paid_at IS NULL OR v_order.paid_at < now() - interval '365 days' THEN
    v_reason := '超过一年的订单微信不再支持退款，请通过微信支付商户平台人工处理';
  ELSIF v_refund.id IS NOT NULL AND v_refund.status IN ('pending', 'processing', 'success') THEN
    v_reason := '该订单已提交过退款，请勿重复发起';
  ELSE
    v_can_refund := true;
  END IF;

  RETURN jsonb_build_object(
    'out_trade_no', v_order.out_trade_no,
    'product_title', v_order.product_title_snapshot,
    'cover_image', v_order.cover_image_snapshot,
    'unit_price_cents', v_order.unit_price_cents,
    'quantity', v_order.quantity,
    'total_amount_cents', v_order.total_amount_cents,
    'paid_amount_cents', v_order.paid_amount_cents,
    'status', v_order.status,
    'requires_shipping', v_order.requires_shipping_snapshot,
    'manual_refund_required', v_order.manual_refund_required,
    'remark', v_order.remark,
    'created_at', v_order.created_at,
    'paid_at', v_order.paid_at,
    'refunded_at', v_order.refunded_at,
    'owner_manager_id', v_order.owner_manager_id_snapshot,
    'owner_manager_name', v_owner_name,
    'is_root', v_is_root,
    'fulfillment_visible', v_fulfillment_visible,
    'buyer_name', CASE WHEN v_fulfillment_visible THEN v_order.contact_name
      ELSE public._mask_person_name(v_order.contact_name) END,
    'buyer_phone', CASE WHEN v_fulfillment_visible THEN v_order.contact_phone
      ELSE public._mask_phone(v_order.contact_phone) END,
    'shipping_address', CASE WHEN v_fulfillment_visible AND v_order.requires_shipping_snapshot
      THEN v_order.shipping_province || v_order.shipping_city || v_order.shipping_district
        || v_order.shipping_address_detail
      ELSE '' END,
    'payee_type', COALESCE(v_pay.payee_type, ''),
    'payee_mch_id', COALESCE(v_pay.mch_id, ''),
    'wechat_transaction_id', COALESCE(v_pay.wechat_transaction_id, ''),
    'refund', CASE WHEN v_refund.id IS NULL THEN NULL ELSE jsonb_build_object(
      'out_refund_no', v_refund.out_refund_no,
      'status', v_refund.status,
      'refund_amount_cents', v_refund.refund_amount_cents,
      'reason', v_refund.reason,
      'failure_summary', v_refund.failure_summary,
      'requested_by_name', v_refund.requested_by_name,
      'submitted_at', v_refund.submitted_at,
      'succeeded_at', v_refund.succeeded_at,
      'created_at', v_refund.created_at
    ) END,
    'refund_events', v_events,
    'can_refund', v_can_refund,
    'refund_disabled_reason', v_reason
  );
END;
$$;

-- 退款预约里同一类脆弱写法一起收紧：payee_type / wechat_transaction_id 为空时不能靠 <> 判定
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

  IF v_actor.id IS NULL OR v_actor.is_disabled OR v_actor.role <> 'manager' THEN
    RAISE EXCEPTION '账号无权发起退款' USING ERRCODE = '42501';
  END IF;
  IF v_actor.parent_manager_id IS NOT NULL THEN
    RAISE EXCEPTION '只有企业负责人可以发起退款' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_order FROM public.orders
  WHERE out_trade_no = p_out_trade_no FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  -- 平台自营订单的归属为空：不能让它落进「归属不匹配」之外的任何缝隙
  IF v_order.owner_manager_id_snapshot IS NULL THEN
    RAISE EXCEPTION '这笔钱不是收进你的商户号，请联系平台处理退款' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_pay FROM public.wechat_miniapp_pay_orders WHERE order_id = v_order.id;
  IF v_pay.id IS NULL
     OR COALESCE(v_pay.payee_type, '') <> 'manager'
     OR v_pay.credential_version_id IS NULL THEN
    RAISE EXCEPTION '这笔钱不是收进你的商户号，请联系平台处理退款' USING ERRCODE = '42501';
  END IF;
  IF v_pay.payee_manager_id IS DISTINCT FROM v_actor.id THEN
    RAISE EXCEPTION '这笔钱不是收进你的商户号，请联系平台处理退款' USING ERRCODE = '42501';
  END IF;
  IF COALESCE(v_pay.wechat_transaction_id, '') = '' THEN
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
    IF v_refund.submit_lease_until IS NOT NULL AND v_refund.submit_lease_until > now() THEN
      RAISE EXCEPTION '退款正在提交中，请稍后刷新查看结果' USING ERRCODE = '22023';
    END IF;

    UPDATE public.wechat_miniapp_refunds
    SET reason = COALESCE(NULLIF(v_reason, ''), reason),
        submit_lease_until = v_lease,
        submitted_at = now(),
        updated_at = now()
    WHERE id = v_refund.id
    RETURNING id INTO v_refund_id;
  ELSE
    INSERT INTO public.wechat_miniapp_refunds (
      order_id, out_trade_no, out_refund_no,
      pay_order_id, pay_account_id, credential_version_id, payee_manager_id,
      refund_amount_cents, total_amount_cents, reason, status,
      submit_lease_until, submitted_at, requested_by, requested_by_name
    ) VALUES (
      v_order.id, v_order.out_trade_no, v_out_refund_no,
      v_pay.id, v_pay.pay_account_id, v_pay.credential_version_id, v_pay.payee_manager_id,
      v_order.total_amount_cents, v_order.total_amount_cents, v_reason, 'pending',
      v_lease, now(), v_actor.id, v_actor.nickname
    )
    RETURNING id INTO v_refund_id;
  END IF;

  IF v_order.status = 'paid' THEN
    UPDATE public.orders SET status = 'refunding', updated_at = now() WHERE id = v_order.id;
  END IF;

  INSERT INTO public.operation_logs (actor_id, actor_name, module, action, target_id, detail)
  VALUES (
    v_actor.id, v_actor.nickname, 'shop_order', '发起微信全额退款', v_order.id::text,
    jsonb_build_object(
      'out_trade_no', v_order.out_trade_no,
      'out_refund_no', v_out_refund_no,
      'amount_cents', v_order.total_amount_cents,
      'reason', v_reason
    )
  );

  RETURN jsonb_build_object(
    'refund_id', v_refund_id,
    'out_refund_no', v_out_refund_no,
    'out_trade_no', v_order.out_trade_no,
    'transaction_id', v_pay.wechat_transaction_id,
    'refund_amount_cents', v_order.total_amount_cents,
    'total_amount_cents', v_order.total_amount_cents,
    'credential_version_id', v_pay.credential_version_id,
    'reason', v_reason
  );
END;
$$;

REVOKE ALL ON FUNCTION public.manager_get_shop_order(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.manager_get_shop_order(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.manager_get_shop_order(text) TO authenticated;

REVOKE ALL ON FUNCTION public.reserve_manager_wechat_full_refund(text, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reserve_manager_wechat_full_refund(text, uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.reserve_manager_wechat_full_refund(text, uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_manager_wechat_full_refund(text, uuid, text) TO service_role;