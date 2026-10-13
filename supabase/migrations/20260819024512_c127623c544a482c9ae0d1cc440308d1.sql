-- 商户订单可见性：商品归属本企业 OR 下单商城是本企业（feature 189）
-- 平台严选商品在本店卖出后，本店也能看到这单（发货/退款责任不变，仍归平台）。
-- 行上补 product_source_type / shop_manager_id，供前端标「自营 / 平台严选」。

CREATE OR REPLACE FUNCTION public.manager_list_shop_orders(
  p_status text[] DEFAULT NULL,
  p_keyword text DEFAULT NULL,
  p_cursor_created_at timestamptz DEFAULT NULL,
  p_cursor_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_scope jsonb := public._resolve_manager_scope(auth.uid());
  v_root uuid := (v_scope->>'root_id')::uuid;
  v_is_root boolean := (v_scope->>'is_root')::boolean;
  v_owners uuid[] := public._manager_visible_owner_ids(auth.uid(), v_root, v_is_root);
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  v_keyword text := NULLIF(btrim(COALESCE(p_keyword, '')), '');
  v_rows jsonb;
  v_count integer;
BEGIN
  SELECT
    COALESCE(jsonb_agg(row_json ORDER BY created_at DESC, id DESC), '[]'::jsonb),
    count(*)
  INTO v_rows, v_count
  FROM (
    SELECT
      o.created_at,
      o.id,
      jsonb_build_object(
        'out_trade_no', o.out_trade_no,
        'product_title', o.product_title_snapshot,
        'cover_image', o.cover_image_snapshot,
        'quantity', o.quantity,
        'total_amount_cents', o.total_amount_cents,
        'status', o.status,
        'requires_shipping', o.requires_shipping_snapshot,
        'manual_refund_required', o.manual_refund_required,
        'created_at', o.created_at,
        'paid_at', o.paid_at,
        'buyer_name_masked', public._mask_person_name(o.contact_name),
        'buyer_phone_masked', public._mask_phone(o.contact_phone),
        'owner_manager_id', o.owner_manager_id_snapshot,
        'owner_manager_name', COALESCE(op.nickname, ''),
        'product_source_type', o.product_source_type_snapshot,
        'shop_manager_id', o.shop_manager_id_snapshot,
        'payee_type', COALESCE(w.payee_type, ''),
        'refund_status', COALESCE(r.status, ''),
        'id', o.id
      ) AS row_json
    FROM public.orders o
    LEFT JOIN public.profiles op ON op.id = o.owner_manager_id_snapshot
    LEFT JOIN public.wechat_miniapp_pay_orders w ON w.order_id = o.id
    LEFT JOIN public.wechat_miniapp_refunds r ON r.order_id = o.id
    WHERE (
        o.owner_manager_id_snapshot = ANY(v_owners)
        OR o.shop_manager_id_snapshot = v_root
      )
      AND (p_status IS NULL OR array_length(p_status, 1) IS NULL OR o.status = ANY(p_status))
      AND (
        v_keyword IS NULL
        OR o.product_title_snapshot ILIKE '%' || v_keyword || '%'
        OR o.out_trade_no ILIKE '%' || v_keyword || '%'
      )
      AND (
        p_cursor_created_at IS NULL OR p_cursor_id IS NULL
        OR (o.created_at, o.id) < (p_cursor_created_at, p_cursor_id)
      )
    ORDER BY o.created_at DESC, o.id DESC
    LIMIT v_limit + 1
  ) page;

  RETURN jsonb_build_object(
    'items', CASE WHEN v_count > v_limit
      THEN (SELECT jsonb_agg(e) FROM (SELECT e FROM jsonb_array_elements(v_rows) e LIMIT v_limit) t)
      ELSE v_rows END,
    'has_more', v_count > v_limit,
    'is_root', v_is_root,
    'scope_owner_count', array_length(v_owners, 1)
  );
END;
$$;

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
  -- 可见：商品归属本企业 OR 下单商城是本企业
  IF v_order IS NULL OR NOT (
    v_order.owner_manager_id_snapshot = ANY(v_owners)
    OR v_order.shop_manager_id_snapshot = v_root
  ) THEN
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

  IF NOT v_is_root THEN
    v_reason := '只有企业负责人可以发起退款';
  ELSIF v_order.status = 'refunded' THEN
    v_reason := '该订单已完成退款';
  ELSIF v_order.status = 'refunding' THEN
    v_reason := '退款正在处理中，请稍后刷新查看结果';
  ELSIF v_order.status <> 'paid' THEN
    v_reason := '只有已支付的订单可以退款';
  ELSIF v_pay.id IS NULL OR v_pay.payee_type <> 'manager' OR v_pay.credential_version_id IS NULL THEN
    v_reason := '这笔钱不是收进你的商户号，请联系平台处理退款';
  ELSIF v_pay.payee_manager_id IS DISTINCT FROM v_root THEN
    v_reason := '这笔钱不是收进你的商户号，请联系平台处理退款';
  ELSIF v_pay.wechat_transaction_id = '' THEN
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
    'refund_disabled_reason', v_reason
  );
END;
$$;

REVOKE ALL ON FUNCTION public.manager_list_shop_orders(text[], text, timestamptz, uuid, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.manager_get_shop_order(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.manager_list_shop_orders(text[], text, timestamptz, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_get_shop_order(text) TO authenticated;