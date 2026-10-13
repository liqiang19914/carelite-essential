-- ============================================================================
-- 商城履约 + 积分体系 批次 2b：订单创建规范化 + 积分兑换下单/取消 + 人工调整 + 流水分页
-- ============================================================================

-- ─────────────────────────────────────────────────────────────
-- 2b-1) 订单创建规范化触发器
--   刻意做成表级触发器而不是去改 create_shop_order / create_virtual_card_order：
--   这样所有创建路径（含将来新增的）都自动获得一致的履约初值，
--   也不必触碰已加固的下单与支付函数。
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._normalize_order_on_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_requires_shipping boolean;
  v_sale_mode         text;
BEGIN
  IF NEW.product_id IS NOT NULL THEN
    SELECT p.requires_shipping, p.sale_mode
      INTO v_requires_shipping, v_sale_mode
    FROM public.products p
    WHERE p.id = NEW.product_id;

    -- 现金下单路径不得买到积分兑换商品（覆盖所有现金创建路径）
    IF NEW.pay_mode = 'cash' AND v_sale_mode = 'points' THEN
      RAISE EXCEPTION '该商品只能用积分兑换，不能现金购买' USING ERRCODE = '22023';
    END IF;
    -- 积分兑换单必须买积分商品
    IF NEW.pay_mode = 'points' AND v_sale_mode IS DISTINCT FROM 'points' THEN
      RAISE EXCEPTION '该商品不是积分兑换商品' USING ERRCODE = '22023';
    END IF;

    -- 是否需要发货以商品为准（create_shop_order 未显式传入，靠列默认值 true，
    -- 虚拟商品若走该路径会被错标成待发货，这里统一按商品纠正）
    IF v_requires_shipping IS NOT NULL THEN
      NEW.requires_shipping_snapshot := v_requires_shipping;
    END IF;
  END IF;

  -- 履约初值：虚拟商品永不进履约；实体商品进待发货
  IF NEW.requires_shipping_snapshot IS DISTINCT FROM true THEN
    NEW.fulfillment_status := 'not_required';
  ELSIF NEW.fulfillment_status = 'not_required' THEN
    NEW.fulfillment_status := 'pending_ship';
  END IF;

  -- 发货责任方：商户私域商品由该商户发货，平台商品为 NULL 由平台后台发货
  IF NEW.fulfillment_manager_id_snapshot IS NULL THEN
    NEW.fulfillment_manager_id_snapshot := NEW.owner_manager_id_snapshot;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS orders_normalize_on_insert ON public.orders;
CREATE TRIGGER orders_normalize_on_insert
  BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public._normalize_order_on_insert();


-- ─────────────────────────────────────────────────────────────
-- 2b-2) 积分兑换下单
--   加锁顺序固定为「先 SKU 行、后余额行」，与取消路径一致，避免死锁。
--   积分单创建即视为已支付（不进任何支付网关），因此当场扣库存。
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.create_points_order(
  p_out_trade_no text,
  p_product_id   uuid,
  p_quantity     integer,
  p_address_id   uuid DEFAULT NULL,
  p_remark       text DEFAULT ''
)
RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_otn     text;
  v_product public.products;
  v_sku     public.product_skus;
  v_addr    public.user_shipping_addresses;
  v_balance integer;
  v_cost    integer;
  v_row     public.orders;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = v_uid AND role = 'user' AND is_disabled = false
  ) THEN
    RAISE EXCEPTION '只有用户端账号可以兑换商品' USING ERRCODE = '42501';
  END IF;

  v_otn := btrim(COALESCE(p_out_trade_no, ''));
  IF v_otn = '' OR char_length(v_otn) > 64 THEN
    RAISE EXCEPTION '兑换单号不合法' USING ERRCODE = '22023';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 999 THEN
    RAISE EXCEPTION '兑换数量必须在 1 到 999 之间' USING ERRCODE = '22023';
  END IF;
  IF char_length(COALESCE(p_remark, '')) > 200 THEN
    RAISE EXCEPTION '备注最多 200 字' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_product FROM public.products WHERE id = p_product_id;
  IF v_product.id IS NULL THEN
    RAISE EXCEPTION '商品不存在' USING ERRCODE = '22023';
  END IF;
  IF v_product.status <> 'active' THEN
    RAISE EXCEPTION '该商品已下架' USING ERRCODE = '22023';
  END IF;
  IF v_product.sale_mode IS DISTINCT FROM 'points' THEN
    RAISE EXCEPTION '该商品不支持积分兑换' USING ERRCODE = '22023';
  END IF;

  -- 第一把锁：SKU 行
  SELECT * INTO v_sku
  FROM public.product_skus
  WHERE product_id = p_product_id AND is_default = true
  LIMIT 1
  FOR UPDATE;

  IF v_sku.id IS NULL THEN
    RAISE EXCEPTION '商品规格不存在' USING ERRCODE = '22023';
  END IF;
  IF v_sku.is_active = false THEN
    RAISE EXCEPTION '该商品规格已停用' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(v_sku.points_price, 0) <= 0 THEN
    RAISE EXCEPTION '该商品尚未设置积分价' USING ERRCODE = '22023';
  END IF;
  IF v_sku.stock < p_quantity THEN
    RAISE EXCEPTION '库存不足，当前仅剩 % 件', v_sku.stock USING ERRCODE = '22023';
  END IF;

  v_cost := v_sku.points_price * p_quantity;

  -- 实体商品必须有收货地址，且地址必须属于本人
  IF v_product.requires_shipping = true THEN
    IF p_address_id IS NULL THEN
      RAISE EXCEPTION '请先选择收货地址' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_addr
    FROM public.user_shipping_addresses
    WHERE id = p_address_id AND user_id = v_uid;
    IF v_addr.id IS NULL THEN
      RAISE EXCEPTION '收货地址不存在' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- 第二把锁：余额行。先建行再锁，锁内校验余额，避免并发超兑。
  INSERT INTO public.points_balances (user_id) VALUES (v_uid)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT b.balance INTO v_balance
  FROM public.points_balances b
  WHERE b.user_id = v_uid
  FOR UPDATE;

  IF COALESCE(v_balance, 0) < v_cost THEN
    RAISE EXCEPTION '积分不足，本次需要 % 分，当前可用 % 分', v_cost, COALESCE(v_balance, 0)
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.orders (
    out_trade_no, user_id, product_id, sku_id,
    product_title_snapshot, cover_image_snapshot,
    unit_price_cents, quantity, total_amount_cents, paid_amount_cents,
    pay_mode, unit_points, points_amount,
    product_source_type_snapshot, owner_manager_id_snapshot,
    status, paid_at, stock_decremented, preferred_payment_method,
    contact_name, contact_phone, shipping_province, shipping_city,
    shipping_district, shipping_address_detail, remark,
    requires_shipping_snapshot
  ) VALUES (
    v_otn, v_uid, v_product.id, v_sku.id,
    v_product.title, COALESCE(v_product.cover_image_url, ''),
    0, p_quantity, 0, 0,
    'points', v_sku.points_price, v_cost,
    v_product.source_type, v_product.owner_manager_id,
    'paid', now(), true, NULL,
    COALESCE(v_addr.contact_name, ''), COALESCE(v_addr.contact_phone, ''),
    COALESCE(v_addr.province, ''), COALESCE(v_addr.city, ''),
    COALESCE(v_addr.district, ''), COALESCE(v_addr.address_detail, ''),
    COALESCE(p_remark, ''),
    COALESCE(v_product.requires_shipping, true)
  )
  RETURNING * INTO v_row;

  UPDATE public.product_skus
  SET stock = stock - p_quantity,
      updated_at = now()
  WHERE id = v_sku.id;

  PERFORM public._post_points_delta(
    v_uid, -v_cost, 'points_redeem',
    '积分兑换「' || v_product.title || '」（单号 ' || v_otn || '）',
    'points_redeem:' || v_otn,
    'order', v_row.id, NULL
  );

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_points_order(text, uuid, integer, uuid, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 2b-3) 取消积分兑换单（仅未发货可取消），等额退回积分并还原库存
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.user_cancel_points_order(p_out_trade_no text)
RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.orders;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row
  FROM public.orders
  WHERE out_trade_no = p_out_trade_no AND user_id = v_uid
  FOR UPDATE;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF v_row.pay_mode IS DISTINCT FROM 'points' THEN
    RAISE EXCEPTION '该订单不是积分兑换单' USING ERRCODE = '22023';
  END IF;
  IF v_row.status IS DISTINCT FROM 'paid' THEN
    RAISE EXCEPTION '该订单当前状态不可取消' USING ERRCODE = '22023';
  END IF;
  IF v_row.fulfillment_status NOT IN ('not_required', 'pending_ship') THEN
    RAISE EXCEPTION '商品已发出，无法取消，请提交退货申请' USING ERRCODE = '22023';
  END IF;

  -- 锁顺序与下单一致：先 SKU 行、后余额行
  IF v_row.sku_id IS NOT NULL THEN
    PERFORM 1 FROM public.product_skus WHERE id = v_row.sku_id FOR UPDATE;
    UPDATE public.product_skus
    SET stock = stock + v_row.quantity, updated_at = now()
    WHERE id = v_row.sku_id;
  END IF;

  UPDATE public.orders
  SET status = 'cancelled', cancelled_at = now(), updated_at = now()
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  -- 等额补偿流水（不修改原扣减流水，台账只增不改）
  PERFORM public._post_points_delta(
    v_uid, v_row.points_amount, 'points_redeem_refund',
    '取消积分兑换，退回积分（单号 ' || v_row.out_trade_no || '）',
    'points_redeem_refund:' || v_row.id::text,
    'order', v_row.id, NULL
  );

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.user_cancel_points_order(text) TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 2b-4) 管理员人工调整积分（由 Edge Function 以服务端身份调用）
--   操作人显式传入并校验为管理员：Edge Function 里 auth.uid() 为空，
--   不能依赖它做权限判断。
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_adjust_user_points(
  p_user_id     uuid,
  p_delta       integer,
  p_reason_text text,
  p_request_id  text,
  p_operator_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_reason  text;
  v_balance integer;
BEGIN
  IF p_operator_id IS NULL OR NOT public.is_admin(p_operator_id) THEN
    RAISE EXCEPTION '只有平台管理员可以调整积分' USING ERRCODE = '42501';
  END IF;

  IF p_user_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user_id) THEN
    RAISE EXCEPTION '找不到该用户' USING ERRCODE = '22023';
  END IF;

  IF p_delta IS NULL OR p_delta = 0 THEN
    RAISE EXCEPTION '积分变动值必须是非零整数' USING ERRCODE = '22023';
  END IF;
  IF abs(p_delta) > 1000000 THEN
    RAISE EXCEPTION '单次调整幅度过大，请分次操作' USING ERRCODE = '22023';
  END IF;

  v_reason := btrim(COALESCE(p_reason_text, ''));
  IF v_reason = '' THEN
    RAISE EXCEPTION '必须填写调整原因' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_reason) > 200 THEN
    RAISE EXCEPTION '调整原因最多 200 字' USING ERRCODE = '22023';
  END IF;

  IF p_request_id IS NULL OR btrim(p_request_id) = '' THEN
    RAISE EXCEPTION '缺少请求号，无法保证不重复入账' USING ERRCODE = '22023';
  END IF;

  v_balance := public._post_points_delta(
    p_user_id, p_delta, 'manual_adjustment', v_reason,
    'manual:' || btrim(p_request_id), NULL, NULL, p_operator_id
  );

  RETURN jsonb_build_object('balance', v_balance, 'delta', p_delta);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_adjust_user_points(uuid, integer, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_adjust_user_points(uuid, integer, text, text, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.admin_adjust_user_points(uuid, integer, text, text, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_adjust_user_points(uuid, integer, text, text, uuid) TO service_role;


-- ─────────────────────────────────────────────────────────────
-- 2b-5) 用户积分概览与流水键集分页
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_my_points_summary()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_bal public.points_balances;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_bal FROM public.points_balances WHERE user_id = v_uid;

  RETURN jsonb_build_object(
    'balance',       COALESCE(v_bal.balance, 0),
    'total_earned',  COALESCE(v_bal.total_earned, 0),
    'total_spent',   COALESCE(v_bal.total_spent, 0),
    'rules', jsonb_build_object(
      'daily_weighing', public._points_rule_amount('points_daily_weighing_amount'),
      'daily_login',    public._points_rule_amount('points_daily_login_amount'),
      'paid_order',     public._points_rule_amount('points_paid_order_amount')
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_points_summary() TO authenticated;


CREATE OR REPLACE FUNCTION public.get_my_points_ledger(
  p_limit             integer     DEFAULT 20,
  p_before_created_at timestamptz DEFAULT NULL,
  p_before_id         uuid        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_limit integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);

  RETURN (
    SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC, x.id DESC), '[]'::jsonb)
    FROM (
      SELECT l.id, l.delta, l.balance_after, l.reason_code, l.reason_text, l.created_at
      FROM public.points_ledger l
      WHERE l.user_id = v_uid
        AND (
          p_before_created_at IS NULL
          OR p_before_id IS NULL
          OR (l.created_at, l.id) < (p_before_created_at, p_before_id)
        )
      ORDER BY l.created_at DESC, l.id DESC
      LIMIT v_limit
    ) x
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_points_ledger(integer, timestamptz, uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 2b-6) 自检：在子事务里真实跑一遍记账核心，跑完回滚。
--   若幂等或余额推进有问题，本次迁移会整体失败而不是把坏代码带上线。
-- ─────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_user uuid;
  v_b1   integer;
  v_b2   integer;
  v_cnt  integer;
  v_key  text := 'selftest:' || gen_random_uuid()::text;
BEGIN
  SELECT id INTO v_user FROM public.profiles LIMIT 1;
  IF v_user IS NULL THEN
    RAISE NOTICE '自检跳过：库中暂无用户';
    RETURN;
  END IF;

  BEGIN
    v_b1 := public._post_points_delta(v_user, 15, 'manual_adjustment', '自检', v_key, NULL, NULL, v_user);
    v_b2 := public._post_points_delta(v_user, 15, 'manual_adjustment', '自检', v_key, NULL, NULL, v_user);

    SELECT count(*) INTO v_cnt FROM public.points_ledger WHERE idempotency_key = v_key;

    IF v_cnt <> 1 THEN
      RAISE EXCEPTION '自检失败：同一幂等键产生了 % 条流水', v_cnt;
    END IF;
    IF v_b1 IS DISTINCT FROM v_b2 THEN
      RAISE EXCEPTION '自检失败：重复调用返回的余额不一致（% vs %）', v_b1, v_b2;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.points_balances WHERE user_id = v_user AND balance = v_b1
    ) THEN
      RAISE EXCEPTION '自检失败：余额行未与流水同步';
    END IF;

    RAISE NOTICE '自检通过：幂等生效，余额 %', v_b1;
    -- 主动抛出以回滚整个子事务，自检数据不落库
    RAISE EXCEPTION 'SELFTEST_ROLLBACK';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM <> 'SELFTEST_ROLLBACK' THEN
        RAISE;
      END IF;
  END;
END $$;