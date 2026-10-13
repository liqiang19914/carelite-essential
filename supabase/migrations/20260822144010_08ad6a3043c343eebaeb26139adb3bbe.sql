-- 线下交付没有物流状态机：核销不推进 fulfillment（保持 not_required），
-- 否则 completed 会触发 shipping_info_check 物流字段约束
CREATE OR REPLACE FUNCTION public.verify_offline_store_order(p_order_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_order public.orders%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF v_order.payment_channel <> 'offline_store' THEN
    RAISE EXCEPTION '这不是门店线下订单' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.stores s
    WHERE s.id = v_order.store_id
      AND s.operator_user_id = v_uid
      AND s.status = 'active'
  ) THEN
    RAISE EXCEPTION '只有这家门店的经营账号才能核销' USING ERRCODE = '42501';
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