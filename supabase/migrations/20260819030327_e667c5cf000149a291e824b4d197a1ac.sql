-- 商城管理新增用户评价（feature 190）
-- 商户按「订单可见范围」读评价：商品归属本企业 OR 下单商城是本企业（与订单列表同一口径）。
-- 支持按星级筛选、按商品名或订单号搜索。评价正文与晒图在此露出。

CREATE OR REPLACE FUNCTION public.manager_list_order_reviews(
  p_rating integer DEFAULT NULL,
  p_keyword text DEFAULT NULL,
  p_cursor_created_at timestamptz DEFAULT NULL,
  p_cursor_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
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
  v_rows    jsonb;
  v_count   integer;
BEGIN
  IF p_rating IS NOT NULL AND (p_rating < 1 OR p_rating > 5) THEN
    RAISE EXCEPTION '星级必须在 1 到 5 之间' USING ERRCODE = '22023';
  END IF;

  SELECT
    COALESCE(jsonb_agg(row_json ORDER BY created_at DESC, id DESC), '[]'::jsonb),
    count(*)
  INTO v_rows, v_count
  FROM (
    SELECT
      rv.created_at,
      rv.id,
      jsonb_build_object(
        'id', rv.id,
        'rating', rv.rating,
        'content', COALESCE(rv.content, ''),
        'images', COALESCE(rv.images, '[]'::jsonb),
        'created_at', rv.created_at,
        'order_id', rv.order_id,
        'out_trade_no', o.out_trade_no,
        'product_title', o.product_title_snapshot,
        'cover_image', o.cover_image_snapshot,
        'product_source_type', o.product_source_type_snapshot,
        'buyer_name_masked', public._mask_person_name(o.contact_name),
        'reviewer_masked', public._mask_person_name(COALESCE(cp.nickname, o.contact_name))
      ) AS row_json
    FROM public.order_reviews rv
    JOIN public.orders o ON o.id = rv.order_id
    LEFT JOIN public.profiles cp ON cp.id = rv.user_id
    WHERE (
        o.owner_manager_id_snapshot = ANY(v_owners)
        OR o.shop_manager_id_snapshot = v_root
      )
      AND (p_rating IS NULL OR rv.rating = p_rating)
      AND (
        v_keyword IS NULL
        OR o.product_title_snapshot ILIKE '%' || v_keyword || '%'
        OR o.out_trade_no ILIKE '%' || v_keyword || '%'
      )
      AND (
        p_cursor_created_at IS NULL OR p_cursor_id IS NULL
        OR (rv.created_at, rv.id) < (p_cursor_created_at, p_cursor_id)
      )
    ORDER BY rv.created_at DESC, rv.id DESC
    LIMIT v_limit + 1
  ) page;

  RETURN jsonb_build_object(
    'items', CASE WHEN v_count > v_limit
      THEN (SELECT jsonb_agg(e) FROM (SELECT e FROM jsonb_array_elements(v_rows) e LIMIT v_limit) t)
      ELSE v_rows END,
    'has_more', v_count > v_limit
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.manager_list_order_reviews(integer, text, timestamptz, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.manager_list_order_reviews(integer, text, timestamptz, uuid, integer) TO authenticated;