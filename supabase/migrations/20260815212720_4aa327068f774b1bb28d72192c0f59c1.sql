-- 平台退货审批：同意现金单时由服务端（云函数）调用的审批落库，只记录同意，不动钱。
-- 与 admin_decide_return_request 的现金分支等价，但显式传操作者 id（云函数用 service_role
-- 调用，没有 auth.uid() 上下文），并返回订单号供后续退款链路继续。
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
  IF v_op IS NULL OR v_op.is_disabled OR v_op.role <> 'admin' THEN
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

REVOKE ALL ON FUNCTION public.admin_approve_return_for_platform_refund(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_approve_return_for_platform_refund(uuid, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.admin_approve_return_for_platform_refund(uuid, uuid, text) FROM authenticated;

GRANT EXECUTE ON FUNCTION public.admin_approve_return_for_platform_refund(uuid, uuid, text) TO service_role;