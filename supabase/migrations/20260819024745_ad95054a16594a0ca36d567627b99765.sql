-- 修正：feature 189 商户订单可见性要落在前端真正用的 7 参重载上。
-- 之前的迁移误改了 5 参旧重载（前端已不用），这里：
-- 1) 删除我误建的 5 参重复版（回到只有 7 参一个 list 重载）
-- 2) 把 7 参版可见性改成「商品归属本企业 OR 下单商城是本企业」，并补 product_source_type / shop_manager_id

DROP FUNCTION IF EXISTS public.manager_list_shop_orders(text[], text, timestamptz, uuid, integer);

CREATE OR REPLACE FUNCTION public.manager_list_shop_orders(
  p_status text[] DEFAULT NULL::text[],
  p_keyword text DEFAULT NULL::text,
  p_cursor_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_cursor_id uuid DEFAULT NULL::uuid,
  p_limit integer DEFAULT 20,
  p_fulfillment text[] DEFAULT NULL::text[],
  p_pay_mode text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_scope   jsonb := public._resolve_manager_scope(auth.uid());
  v_root    uuid := (v_scope->>'root_id')::uuid;
  v_is_root boolean := (v_scope->>'is_root')::boolean;
  v_owners  uuid[] := public._manager_visible_owner_ids(auth.uid(), v_root, v_is_root);
  v_limit   integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  v_keyword text := NULLIF(btrim(COALESCE(p_keyword, '')), '');
  v_pay     text := NULLIF(btrim(COALESCE(p_pay_mode, '')), '');
  v_rows    jsonb;
  v_count   integer;
BEGIN
  IF v_pay IS NOT NULL AND v_pay NOT IN ('cash', 'points') THEN
    RAISE EXCEPTION '未知的付款方式' USING ERRCODE = '22023';
  END IF;

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
        'pay_mode', o.pay_mode,
        'points_amount', o.points_amount,
        'fulfillment_status',
          public._effective_fulfillment_status(o.fulfillment_status, o.auto_receive_at),
        'carrier_name', COALESCE(o.carrier_name, ''),
        'tracking_no', COALESCE(o.tracking_no, ''),
        'shipped_at', o.shipped_at,
        'auto_receive_at', o.auto_receive_at,
        'is_mine_to_ship', (o.fulfillment_manager_id_snapshot IS NOT NULL),
        'return_request_status', COALESCE(rr.status, ''),
        'review_rating', rv.rating,
        'id', o.id
      ) AS row_json
    FROM public.orders o
    LEFT JOIN public.profiles op ON op.id = o.owner_manager_id_snapshot
    LEFT JOIN public.wechat_miniapp_pay_orders w ON w.order_id = o.id
    LEFT JOIN public.wechat_miniapp_refunds r ON r.order_id = o.id
    LEFT JOIN public.order_reviews rv ON rv.order_id = o.id
    LEFT JOIN LATERAL (
      SELECT x.status FROM public.order_return_requests x
      WHERE x.order_id = o.id
      ORDER BY x.created_at DESC, x.id DESC
      LIMIT 1
    ) rr ON true
    WHERE (
        o.owner_manager_id_snapshot = ANY(v_owners)
        OR o.shop_manager_id_snapshot = v_root
      )
      AND (p_status IS NULL OR array_length(p_status, 1) IS NULL OR o.status = ANY(p_status))
      AND (v_pay IS NULL OR COALESCE(o.pay_mode, 'cash') = v_pay)
      AND (
        p_fulfillment IS NULL OR array_length(p_fulfillment, 1) IS NULL
        OR public._effective_fulfillment_status(o.fulfillment_status, o.auto_receive_at)
             = ANY(p_fulfillment)
        OR ('has_return' = ANY(p_fulfillment) AND rr.status IS NOT NULL
            AND rr.status IN ('pending', 'approved'))
      )
      AND (
        v_keyword IS NULL
        OR o.product_title_snapshot ILIKE '%' || v_keyword || '%'
        OR o.out_trade_no ILIKE '%' || v_keyword || '%'
        OR o.tracking_no ILIKE '%' || v_keyword || '%'
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
$function$;

REVOKE ALL ON FUNCTION public.manager_list_shop_orders(text[], text, timestamptz, uuid, integer, text[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.manager_list_shop_orders(text[], text, timestamptz, uuid, integer, text[], text) TO authenticated;