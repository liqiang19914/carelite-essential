-- 修正 feature 189：manager_get_shop_order 之前误基于旧版重写，丢了 review/return_request/can_ship 等字段。
-- 基于完整最新版（含全部字段），只把可见性改成「商品归属本企业 OR 下单商城是本企业」，
-- 并补 product_source_type / shop_manager_id。

CREATE OR REPLACE FUNCTION public.manager_get_shop_order(p_out_trade_no text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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
  v_review public.order_reviews;
  v_return public.order_return_requests;
  v_owner_name text := '';
  v_events jsonb := '[]'::jsonb;
  v_fulfillment_visible boolean;
  v_can_refund boolean := false;
  v_reason text := '';
  v_ef text;
  v_can_ship boolean := false;
  v_ship_reason text := '';
  v_has_open_return boolean;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE out_trade_no = p_out_trade_no;

  -- 可见：商品归属本企业 OR 下单商城是本企业。
  -- owner 为 NULL（平台严选）时靠 shop_manager_id_snapshot = v_root 命中；
  -- 两道都用显式比较，避免 NULL 三值逻辑误判。
  IF v_order.id IS NULL
     OR NOT (
       (v_order.owner_manager_id_snapshot IS NOT NULL AND v_order.owner_manager_id_snapshot = ANY(v_owners))
       OR v_order.shop_manager_id_snapshot = v_root
     ) THEN
    RAISE EXCEPTION '订单不存在或不属于你' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(nickname, '') INTO v_owner_name
  FROM public.profiles WHERE id = v_order.owner_manager_id_snapshot;

  SELECT * INTO v_pay FROM public.wechat_miniapp_pay_orders WHERE order_id = v_order.id;
  SELECT * INTO v_refund FROM public.wechat_miniapp_refunds WHERE order_id = v_order.id;
  SELECT * INTO v_review FROM public.order_reviews WHERE order_id = v_order.id;

  SELECT * INTO v_return FROM public.order_return_requests
  WHERE order_id = v_order.id
  ORDER BY created_at DESC, id DESC
  LIMIT 1;

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
  v_ef := public._effective_fulfillment_status(v_order.fulfillment_status, v_order.auto_receive_at);

  v_has_open_return := EXISTS (
    SELECT 1 FROM public.order_return_requests r
    WHERE r.order_id = v_order.id AND r.status IN ('pending', 'approved')
  );

  -- 能不能发货：按履约责任（fulfillment_manager_id_snapshot）判断，与商城归属无关
  IF v_order.fulfillment_manager_id_snapshot IS NULL THEN
    v_ship_reason := '该订单由平台负责发货';
  ELSIF NOT (v_order.fulfillment_manager_id_snapshot = ANY(v_owners)) THEN
    v_ship_reason := '该订单不在你的发货范围内';
  ELSIF v_order.requires_shipping_snapshot IS DISTINCT FROM true THEN
    v_ship_reason := '虚拟商品无需发货';
  ELSIF v_order.status IS DISTINCT FROM 'paid' THEN
    v_ship_reason := '只有已支付的订单可以发货';
  ELSIF v_has_open_return THEN
    v_ship_reason := '有正在处理的退货申请，请先处理申请';
  ELSIF v_ef = 'pending_ship' THEN
    v_can_ship := true;
  ELSE
    v_ship_reason := '该订单已发货';
  END IF;

  -- 能不能发起退款：按实际收款方判断，与商城归属无关
  IF v_order.pay_mode = 'points' THEN
    v_reason := '积分兑换单没有现金支付，请在退货申请里退回积分';
  ELSIF NOT v_is_root THEN
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
    'product_source_type', v_order.product_source_type_snapshot,
    'shop_manager_id', v_order.shop_manager_id_snapshot,
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
    'refund_disabled_reason', v_reason,
    'pay_mode', v_order.pay_mode,
    'unit_points', v_order.unit_points,
    'points_amount', v_order.points_amount,
    'fulfillment_status', v_ef,
    'carrier_name', COALESCE(v_order.carrier_name, ''),
    'tracking_no', COALESCE(v_order.tracking_no, ''),
    'shipped_at', v_order.shipped_at,
    'auto_receive_at', v_order.auto_receive_at,
    'received_at', v_order.received_at,
    'completed_at', v_order.completed_at,
    'can_ship', v_can_ship,
    'ship_disabled_reason', v_ship_reason,
    'review', CASE WHEN v_review.id IS NULL THEN NULL ELSE jsonb_build_object(
      'rating', v_review.rating,
      'content', v_review.content,
      'images', v_review.images,
      'created_at', v_review.created_at
    ) END,
    'return_request', CASE WHEN v_return.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_return.id,
      'handler_scope', v_return.handler_scope,
      'status', v_return.status,
      'reason_code', v_return.reason_code,
      'reason_text', v_return.reason_text,
      'images', v_return.images,
      'decision_note', v_return.decision_note,
      'decided_at', v_return.decided_at,
      'created_at', v_return.created_at
    ) END,
    'can_decide_return', (
      v_return.id IS NOT NULL
      AND v_return.status = 'pending'
      AND v_return.handler_scope = 'merchant'
      AND v_return.handler_manager_id IS NOT NULL
      AND v_return.handler_manager_id = v_root
      AND v_is_root
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.manager_get_shop_order(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.manager_get_shop_order(text) TO authenticated;