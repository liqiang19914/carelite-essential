-- 门店线下订单只出现在「门店订单」页签：普通订单列表与角标统计一律排除
DROP FUNCTION IF EXISTS public.get_my_orders(text, integer, timestamp with time zone, uuid, uuid);

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
        AND COALESCE(o.is_demo, false) = false
        AND public._owner_in_shop_scope(o.owner_manager_id_snapshot, p_shop_root)
        AND COALESCE(o.payment_channel, '') <> 'offline_store'
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

DROP FUNCTION IF EXISTS public.get_my_order_tab_counts(uuid);

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
        AND COALESCE(o.is_demo, false) = false
        AND public._owner_in_shop_scope(o.owner_manager_id_snapshot, p_shop_root)
        AND COALESCE(o.payment_channel, '') <> 'offline_store'
        AND o.status IN ('pending', 'paid', 'refunding', 'refunded')
    ) t
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_my_order_tab_counts(uuid) TO authenticated, anon, service_role;

