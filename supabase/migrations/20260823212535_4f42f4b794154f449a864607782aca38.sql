-- 282 审查修复：claim 并发/撞码兜底；预览与核销先验门店操作权再探测码；恢复「停业门店不能核销」
CREATE OR REPLACE FUNCTION public.claim_offline_store_payment(p_order_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_order public.orders%ROWTYPE;
  v_code TEXT;
  v_has BOOLEAN;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  -- 加锁读取：与取消/核销并发时在锁内重查状态，不再返回错误终态
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND OR v_order.user_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF v_order.payment_channel <> 'offline_store' THEN
    RAISE EXCEPTION '这不是门店线下订单' USING ERRCODE = '22023';
  END IF;
  IF v_order.offline_status = 'verified' THEN
    RAISE EXCEPTION '订单已经核销过了' USING ERRCODE = '22023';
  END IF;
  IF v_order.offline_status = 'cancelled' THEN
    RAISE EXCEPTION '订单已取消' USING ERRCODE = '22023';
  END IF;

  UPDATE public.orders
     SET offline_status = 'awaiting_verification',
         offline_claimed_at = COALESCE(offline_claimed_at, now()),
         updated_at = now()
   WHERE id = v_order.id AND offline_status = 'awaiting_payment';

  -- 锁内重查：并发重复确认已把状态推到待核销时按幂等继续；其它终态一律报错
  IF NOT FOUND THEN
    SELECT offline_status INTO v_order.offline_status
      FROM public.orders WHERE id = v_order.id;
    IF v_order.offline_status IS DISTINCT FROM 'awaiting_verification' THEN
      RAISE EXCEPTION '订单当前状态无法确认付款' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- 生成 6 位按店唯一码；撞码（极罕见）重试，索引兜底
  SELECT (verify_code IS NULL) INTO v_has FROM public.orders WHERE id = v_order.id;
  IF v_has THEN
    FOR i IN 1..50 LOOP
      v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');
      BEGIN
        UPDATE public.orders SET verify_code = v_code
         WHERE id = v_order.id AND verify_code IS NULL;
        EXIT WHEN FOUND;
      EXCEPTION WHEN unique_violation THEN
        NULL;
      END;
      SELECT (verify_code IS NOT NULL) INTO v_has FROM public.orders WHERE id = v_order.id;
      EXIT WHEN v_has;
    END LOOP;
  END IF;

  -- 50 次仍没生成成功：整体回滚，不静默返回成功
  IF NOT EXISTS (
    SELECT 1 FROM public.orders WHERE id = v_order.id AND verify_code IS NOT NULL
  ) THEN
    RAISE EXCEPTION '核销码生成失败，请稍后重试' USING ERRCODE = '22023';
  END IF;

  RETURN json_build_object('success', true, 'offline_status', 'awaiting_verification');
END;
$function$;

REVOKE ALL ON FUNCTION public.claim_offline_store_payment(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_offline_store_payment(UUID) TO authenticated;

-- 预览核销：6 位码路径先校验调用者对目标门店的操作权，再做任何按码探测
CREATE OR REPLACE FUNCTION public.preview_offline_store_order_by_code(p_code text, p_store_id uuid DEFAULT NULL)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_no text := public.parse_store_order_code(btrim(coalesce(p_code, '')));
  v_order public.orders%ROWTYPE;
  v_is_member boolean;
  v_store_name text;
  v_scope uuid := p_store_id;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF v_no = '' THEN
    RAISE EXCEPTION '核销码不能为空' USING ERRCODE = '22023';
  END IF;

  IF v_no ~ '^[0-9]{6}$' THEN
    -- 6 位数字码：按店查找。未传门店时取调用者的成员门店。
    IF v_scope IS NULL THEN
      SELECT m.store_id INTO v_scope
        FROM public.store_members m
       WHERE m.user_id = v_uid AND m.status = 'active'
       ORDER BY m.created_at ASC
       LIMIT 1;
    END IF;
    -- 先确认调用者有权操作这家门店：无权统一拒绝，不区分码是否存在，堵住码枚举侧信道
    IF v_scope IS NULL
       OR NOT (
         EXISTS (
           SELECT 1 FROM public.store_members m
            WHERE m.store_id = v_scope AND m.user_id = v_uid AND m.status = 'active'
         )
         OR public._can_admin_store(v_scope)
       ) THEN
      RAISE EXCEPTION '你没有权限操作这家门店' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO v_order FROM public.orders
     WHERE verify_code = v_no
       AND store_id = v_scope
       AND payment_channel = 'offline_store';
    IF NOT FOUND THEN
      IF EXISTS (
        SELECT 1 FROM public.orders
         WHERE verify_code = v_no AND payment_channel = 'offline_store'
      ) THEN
        RAISE EXCEPTION '这不是本店订单' USING ERRCODE = '22023';
      ELSE
        RAISE EXCEPTION '核销码无效或已失效' USING ERRCODE = '22023';
      END IF;
    END IF;
  ELSE
    SELECT * INTO v_order FROM public.orders
     WHERE out_trade_no = v_no AND payment_channel = 'offline_store';
    IF NOT FOUND THEN
      RAISE EXCEPTION '没有找到这张核销码对应的订单' USING ERRCODE = '22023';
    END IF;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.store_members m
    WHERE m.store_id = v_order.store_id AND m.user_id = v_uid AND m.status = 'active'
  ) INTO v_is_member;
  IF NOT coalesce(v_is_member, false)
     AND NOT public._can_admin_store(v_order.store_id) THEN
    RAISE EXCEPTION '这不是本店订单' USING ERRCODE = '22023';
  END IF;

  SELECT name INTO v_store_name FROM public.stores WHERE id = v_order.store_id;

  RETURN json_build_object(
    'order_id', v_order.id,
    'out_trade_no', v_order.out_trade_no,
    'product_title', v_order.product_title_snapshot,
    'cover_image_url', v_order.cover_image_snapshot,
    'quantity', v_order.quantity,
    'total_amount_cents', v_order.total_amount_cents,
    'contact_name', v_order.contact_name,
    'contact_phone', CASE
      WHEN public.is_admin(v_uid) THEN v_order.contact_phone
      WHEN v_order.contact_phone ~ '^1[0-9]{10}$' THEN left(v_order.contact_phone, 3) || '****' || right(v_order.contact_phone, 4)
      ELSE v_order.contact_phone
    END,
    'remark', v_order.remark,
    'offline_status', v_order.offline_status,
    'store_name', coalesce(v_store_name, ''),
    'created_at', v_order.created_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.preview_offline_store_order_by_code(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.preview_offline_store_order_by_code(text, uuid) TO authenticated;

-- 按码核销：6 位码路径同样先验门店操作权；恢复「停业门店不能核销」
CREATE OR REPLACE FUNCTION public.verify_offline_store_order_by_code(p_code text, p_store_id uuid DEFAULT NULL)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_no text := public.parse_store_order_code(btrim(coalesce(p_code, '')));
  v_order public.orders%ROWTYPE;
  v_scope uuid := p_store_id;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF v_no = '' THEN
    RAISE EXCEPTION '核销码不能为空' USING ERRCODE = '22023';
  END IF;

  IF v_no ~ '^[0-9]{6}$' THEN
    IF v_scope IS NULL THEN
      SELECT m.store_id INTO v_scope
        FROM public.store_members m
       WHERE m.user_id = v_uid AND m.status = 'active'
       ORDER BY m.created_at ASC
       LIMIT 1;
    END IF;
    IF v_scope IS NULL
       OR NOT (
         EXISTS (
           SELECT 1 FROM public.store_members m
            WHERE m.store_id = v_scope AND m.user_id = v_uid AND m.status = 'active'
         )
         OR public._can_admin_store(v_scope)
       ) THEN
      RAISE EXCEPTION '你没有权限操作这家门店' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO v_order FROM public.orders
     WHERE verify_code = v_no
       AND store_id = v_scope
       AND payment_channel = 'offline_store'
     FOR UPDATE;
    IF NOT FOUND THEN
      IF EXISTS (
        SELECT 1 FROM public.orders
         WHERE verify_code = v_no AND payment_channel = 'offline_store'
      ) THEN
        RAISE EXCEPTION '这不是本店订单' USING ERRCODE = '22023';
      ELSE
        RAISE EXCEPTION '核销码无效或已失效' USING ERRCODE = '22023';
      END IF;
    END IF;
  ELSE
    SELECT * INTO v_order FROM public.orders
     WHERE out_trade_no = v_no AND payment_channel = 'offline_store'
     FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION '没有找到这张核销码对应的订单' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members m
    JOIN public.stores s ON s.id = m.store_id
    WHERE s.id = v_order.store_id AND m.user_id = v_uid AND m.status = 'active'
      AND s.status = 'active'
  ) AND NOT public._can_admin_store(v_order.store_id) THEN
    RAISE EXCEPTION '这不是本店订单' USING ERRCODE = '22023';
  END IF;

  -- 停业门店无论走成员通道还是企业管理员通道都不能核销
  IF NOT EXISTS (
    SELECT 1 FROM public.stores s
    WHERE s.id = v_order.store_id AND s.status = 'active'
  ) THEN
    RAISE EXCEPTION '这家门店已停业，不能核销' USING ERRCODE = '22023';
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

REVOKE ALL ON FUNCTION public.verify_offline_store_order_by_code(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_offline_store_order_by_code(text, uuid) TO authenticated;