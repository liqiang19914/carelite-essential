CREATE OR REPLACE FUNCTION public._owner_in_shop_scope(p_owner_manager_id uuid, p_shop_root uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT CASE
    WHEN p_shop_root IS NULL THEN p_owner_manager_id IS NULL
    WHEN p_owner_manager_id IS NULL THEN false
    ELSE public.get_enterprise_root_manager_id(p_owner_manager_id)
         = public.get_enterprise_root_manager_id(p_shop_root)
  END;
$function$;

GRANT EXECUTE ON FUNCTION public._owner_in_shop_scope(uuid, uuid) TO authenticated, anon, service_role;

-- ── 我的订单列表：加 p_shop_root，OEM 壳只看本店单、平台壳只看平台单 ──
DROP FUNCTION IF EXISTS public.get_my_orders(text, integer, timestamp with time zone, uuid);

CREATE OR REPLACE FUNCTION public.get_my_orders(p_tab text DEFAULT 'all'::text, p_limit integer DEFAULT 10, p_before_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_id uuid DEFAULT NULL::uuid, p_shop_root uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid   uuid := auth.uid();
  v_root  uuid;
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

  IF p_shop_root IS NOT NULL THEN
    v_root := public.get_enterprise_root_manager_id(p_shop_root);
    IF v_root IS NULL THEN
      RETURN '[]'::jsonb;
    END IF;
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
        AND public._owner_in_shop_scope(o.owner_manager_id_snapshot, p_shop_root)
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
$function$;

GRANT EXECUTE ON FUNCTION public.get_my_orders(text, integer, timestamp with time zone, uuid, uuid) TO authenticated, anon, service_role;

-- ── 订单角标：同作用域 ──
DROP FUNCTION IF EXISTS public.get_my_order_tab_counts();

CREATE OR REPLACE FUNCTION public.get_my_order_tab_counts(p_shop_root uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_root uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  IF p_shop_root IS NOT NULL THEN
    v_root := public.get_enterprise_root_manager_id(p_shop_root);
    IF v_root IS NULL THEN
      RETURN jsonb_build_object(
        'pending_payment', 0, 'pending_ship', 0, 'pending_receive', 0,
        'pending_review', 0, 'returns', 0
      );
    END IF;
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
        AND public._owner_in_shop_scope(o.owner_manager_id_snapshot, p_shop_root)
        AND o.status IN ('pending', 'paid', 'refunding', 'refunded')
    ) t
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_my_order_tab_counts(uuid) TO authenticated, anon, service_role;

-- ── 订单详情：同作用域 ──
DROP FUNCTION IF EXISTS public.get_my_order_detail(text);

CREATE OR REPLACE FUNCTION public.get_my_order_detail(p_out_trade_no text, p_shop_root uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid   uuid := auth.uid();
  v_order public.orders;
  v_res   jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  PERFORM public._land_my_due_receipts(v_uid);

  SELECT * INTO v_order FROM public.orders o
  WHERE o.out_trade_no = p_out_trade_no AND o.user_id = v_uid;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;

  IF NOT public._owner_in_shop_scope(v_order.owner_manager_id_snapshot, p_shop_root) THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;

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
  WHERE o.id = v_order.id;

  RETURN v_res;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_my_order_detail(text, uuid) TO authenticated, anon, service_role;