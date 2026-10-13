-- ============================================================================
-- 商城履约 + 积分体系 批次 3b：用户订单六标签键集分页 + 标签计数 + 自动收货有界落库
-- ============================================================================

-- ─────────────────────────────────────────────────────────────
-- 3b-1) 把本人名下已过期的「已发货」落库为「已收货」
--   有界：一次最多处理 50 行，只处理调用者自己的订单，不做全表扫描。
--   本项目没有定时任务基建，所以这一步挂在用户打开订单页时顺带完成；
--   即使一直没人打开，_effective_fulfillment_status 的派生也已经保证
--   各处显示与判断都是「已收货」，落库只是让数据静态化。
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._land_my_due_receipts(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count integer := 0;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN 0;
  END IF;

  WITH due AS (
    SELECT o.id
    FROM public.orders o
    WHERE o.user_id = p_user_id
      AND o.fulfillment_status = 'shipped'
      AND o.auto_receive_at IS NOT NULL
      AND o.auto_receive_at <= now()
    ORDER BY o.auto_receive_at
    LIMIT 50
  )
  UPDATE public.orders o
  SET fulfillment_status = 'received',
      received_at        = COALESCE(o.received_at, o.auto_receive_at),
      updated_at         = now()
  FROM due
  WHERE o.id = due.id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


-- ─────────────────────────────────────────────────────────────
-- 3b-2) 用户订单列表：六标签 + 键集分页
--   标签谓词一律基于「有效履约状态」，不是库里的原始值。
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_my_orders(
  p_tab               text        DEFAULT 'all',
  p_limit             integer     DEFAULT 10,
  p_before_created_at timestamptz DEFAULT NULL,
  p_before_id         uuid        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_limit integer;
  v_tab   text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  v_tab := COALESCE(p_tab, 'all');
  IF v_tab NOT IN ('all', 'pending_payment', 'pending_ship',
                   'pending_receive', 'pending_review', 'returns') THEN
    RAISE EXCEPTION '未知的订单分类' USING ERRCODE = '22023';
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 30);

  PERFORM public._land_my_due_receipts(v_uid);

  RETURN (
    SELECT COALESCE(jsonb_agg(x.row_json ORDER BY x.created_at DESC, x.id DESC), '[]'::jsonb)
    FROM (
      SELECT
        o.id,
        o.created_at,
        to_jsonb(o) || jsonb_build_object(
          'effective_fulfillment_status',
            public._effective_fulfillment_status(o.fulfillment_status, o.auto_receive_at),
          'has_review',        (rv.id IS NOT NULL),
          'review_rating',     rv.rating,
          'return_request_id', rr.id,
          'return_status',     rr.status
        ) AS row_json
      FROM public.orders o
      LEFT JOIN public.order_reviews rv ON rv.order_id = o.id
      LEFT JOIN LATERAL (
        SELECT r.id, r.status
        FROM public.order_return_requests r
        WHERE r.order_id = o.id
        ORDER BY r.created_at DESC, r.id DESC
        LIMIT 1
      ) rr ON true
      WHERE o.user_id = v_uid
        AND (
          p_before_created_at IS NULL
          OR p_before_id IS NULL
          OR (o.created_at, o.id) < (p_before_created_at, p_before_id)
        )
        AND (
          v_tab = 'all'
          OR (v_tab = 'pending_payment' AND o.status = 'pending')
          OR (v_tab = 'pending_ship'
              AND o.status = 'paid'
              AND o.requires_shipping_snapshot = true
              AND public._effective_fulfillment_status(o.fulfillment_status, o.auto_receive_at) = 'pending_ship')
          OR (v_tab = 'pending_receive'
              AND o.status = 'paid'
              AND public._effective_fulfillment_status(o.fulfillment_status, o.auto_receive_at) = 'shipped')
          OR (v_tab = 'pending_review'
              AND o.status = 'paid'
              AND rv.id IS NULL
              AND (
                public._effective_fulfillment_status(o.fulfillment_status, o.auto_receive_at)
                  IN ('received', 'completed')
                OR o.fulfillment_status = 'not_required'
              ))
          OR (v_tab = 'returns'
              AND (rr.id IS NOT NULL OR o.status IN ('refunding', 'refunded')))
        )
      ORDER BY o.created_at DESC, o.id DESC
      LIMIT v_limit
    ) x
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_orders(text, integer, timestamptz, uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 3b-3) 五个订单状态入口的角标计数（「我的」页与订单页共用）
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_my_order_tab_counts()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  RETURN (
    SELECT jsonb_build_object(
      'pending_payment', count(*) FILTER (WHERE t.status = 'pending'),
      'pending_ship',    count(*) FILTER (WHERE t.status = 'paid'
                                           AND t.requires_shipping_snapshot = true
                                           AND t.ef = 'pending_ship'),
      'pending_receive', count(*) FILTER (WHERE t.status = 'paid' AND t.ef = 'shipped'),
      'pending_review',  count(*) FILTER (WHERE t.status = 'paid'
                                           AND NOT t.reviewed
                                           AND (t.ef IN ('received', 'completed')
                                                OR t.fulfillment_status = 'not_required')),
      'returns',         count(*) FILTER (WHERE t.has_return
                                           OR t.status IN ('refunding', 'refunded'))
    )
    FROM (
      SELECT
        o.status,
        o.fulfillment_status,
        o.requires_shipping_snapshot,
        public._effective_fulfillment_status(o.fulfillment_status, o.auto_receive_at) AS ef,
        EXISTS (SELECT 1 FROM public.order_reviews rv WHERE rv.order_id = o.id) AS reviewed,
        EXISTS (SELECT 1 FROM public.order_return_requests r WHERE r.order_id = o.id) AS has_return
      FROM public.orders o
      WHERE o.user_id = v_uid
        AND o.status IN ('pending', 'paid', 'refunding', 'refunded')
    ) t
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_order_tab_counts() TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 3b-4) 单笔订单详情（含履约、物流、评价、退货申请）
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_my_order_detail(p_out_trade_no text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_res jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  PERFORM public._land_my_due_receipts(v_uid);

  SELECT
    to_jsonb(o) || jsonb_build_object(
      'effective_fulfillment_status',
        public._effective_fulfillment_status(o.fulfillment_status, o.auto_receive_at),
      'auto_receive_days', public._points_rule_amount('shop_auto_receive_days'),
      'review', CASE WHEN rv.id IS NULL THEN NULL ELSE to_jsonb(rv) END,
      'return_request', CASE WHEN rr.id IS NULL THEN NULL ELSE to_jsonb(rr) END
    )
  INTO v_res
  FROM public.orders o
  LEFT JOIN public.order_reviews rv ON rv.order_id = o.id
  LEFT JOIN LATERAL (
    SELECT r.* FROM public.order_return_requests r
    WHERE r.order_id = o.id
    ORDER BY r.created_at DESC, r.id DESC
    LIMIT 1
  ) rr ON true
  WHERE o.out_trade_no = p_out_trade_no
    AND o.user_id = v_uid;

  IF v_res IS NULL THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;

  RETURN v_res;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_order_detail(text) TO authenticated;