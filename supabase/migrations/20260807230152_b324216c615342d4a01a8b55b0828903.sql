-- 商户积分兑换商品：把「只有平台能做积分商品」的硬限制换成「平台授权后商户才能做」
-- 1) 去掉写死平台专属的 CHECK
ALTER TABLE public.products
  DROP CONSTRAINT IF EXISTS products_points_platform_only_check;

-- 2) 改成门禁触发器：商户商品要变成积分兑换，必须其所属企业已被平台授予 points_exchange。
--    只在「进入积分模式」这一刻拦（新建即积分 / 现金改积分）；已经是积分商品的后续编辑、
--    改价、下架都不再拦，否则平台一旦回收授权，商户连下架自己的商品都做不到。
CREATE OR REPLACE FUNCTION public.products_guard_points_sale_mode()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
BEGIN
  IF COALESCE(NEW.sale_mode, 'cash') <> 'points' THEN
    RETURN NEW;
  END IF;

  -- 平台严选的积分商品不需要商户授权
  IF NEW.source_type <> 'manager' THEN
    RETURN NEW;
  END IF;

  -- 已经是积分商品：放行后续编辑与下架
  IF TG_OP = 'UPDATE' AND COALESCE(OLD.sale_mode, 'cash') = 'points' THEN
    RETURN NEW;
  END IF;

  IF NEW.owner_manager_id IS NULL THEN
    RAISE EXCEPTION 'points_exchange module not open for this merchant'
      USING ERRCODE = '42501';
  END IF;

  v_root := public.get_enterprise_root_manager_id(NEW.owner_manager_id);

  IF v_root IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.merchant_module_grants g
    WHERE g.manager_id = v_root
      AND g.module_key = 'points_exchange'
      AND g.grant_status = 'granted'
  ) THEN
    RAISE EXCEPTION 'points_exchange module not open for this merchant'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_products_guard_points_sale_mode ON public.products;
CREATE TRIGGER trg_products_guard_points_sale_mode
  BEFORE INSERT OR UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.products_guard_points_sale_mode();

-- 3) 可见性：商户的积分商品对「本企业活跃客户」直接可见，不再要求逐个 share_grants；
--    并且商户自己那个「对客户开放」的开关关掉后立即不可见。
--    现金私域商品的原有 share_grants 授权逻辑一个字没改。
CREATE OR REPLACE FUNCTION public.can_view_product(p_product_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_source TEXT;
  v_owner UUID;
  v_status TEXT;
  v_sale_mode TEXT;
  v_root UUID;
BEGIN
  IF p_product_id IS NULL OR p_user_id IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT source_type, owner_manager_id, status, COALESCE(sale_mode, 'cash')
    INTO v_source, v_owner, v_status, v_sale_mode
    FROM products
    WHERE id = p_product_id;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  -- 1. admin 全可见
  IF EXISTS (
    SELECT 1 FROM profiles WHERE id = p_user_id AND role = 'admin'
  ) THEN
    RETURN TRUE;
  END IF;

  -- 2. 平台严选 + active：所有用户可见
  IF v_source = 'platform' AND v_status = 'active' THEN
    RETURN TRUE;
  END IF;

  -- 3. 平台严选 + 非 active：仅 admin（上面已拦截）
  IF v_source = 'platform' THEN
    RETURN FALSE;
  END IF;

  -- 4. 管理师私域：作者本人可见所有状态
  IF v_source = 'manager' AND v_owner = p_user_id THEN
    RETURN TRUE;
  END IF;

  -- 5. 管理师私域 active：通过 share_grants 显式授权才可见
  IF v_source = 'manager' AND v_status = 'active' THEN
    -- 5.1 specific 直接授权给该用户
    IF EXISTS (
      SELECT 1 FROM product_share_grants g
      WHERE g.product_id = p_product_id
        AND g.audience = 'specific'
        AND g.client_id = p_user_id
        AND g.revoked_at IS NULL
        AND (g.expires_at IS NULL OR g.expires_at > NOW())
    ) THEN RETURN TRUE; END IF;

    -- 5.2 all_clients：用户是该管理师的活跃客户
    IF EXISTS (
      SELECT 1 FROM product_share_grants g
      INNER JOIN client_relations cr
        ON cr.manager_id = g.manager_id
       AND cr.client_id = p_user_id
       AND cr.status = 'active'
      WHERE g.product_id = p_product_id
        AND g.audience = 'all_clients'
        AND g.revoked_at IS NULL
        AND (g.expires_at IS NULL OR g.expires_at > NOW())
    ) THEN RETURN TRUE; END IF;

    -- 5.3 tag：用户在该管理师的标签下
    IF EXISTS (
      SELECT 1 FROM product_share_grants g
      INNER JOIN client_relations cr
        ON cr.manager_id = g.manager_id
       AND cr.client_id = p_user_id
       AND cr.status = 'active'
      INNER JOIN client_tag_relations ctr
        ON ctr.client_relation_id = cr.id
       AND ctr.tag_id = g.tag_id
      WHERE g.product_id = p_product_id
        AND g.audience = 'tag'
        AND g.revoked_at IS NULL
        AND (g.expires_at IS NULL OR g.expires_at > NOW())
    ) THEN RETURN TRUE; END IF;

    -- 6. 积分兑换商品：本企业的活跃客户直接可见，前提是该企业的积分兑换对客户开放
    IF v_sale_mode = 'points' AND v_owner IS NOT NULL THEN
      v_root := get_enterprise_root_manager_id(v_owner);
      IF v_root IS NOT NULL
         AND EXISTS (
           SELECT 1 FROM merchant_module_grants g
           WHERE g.manager_id = v_root
             AND g.module_key = 'points_exchange'
             AND g.grant_status = 'granted'
             AND g.is_enabled = TRUE
         )
         AND EXISTS (
           SELECT 1 FROM client_relations cr
           WHERE cr.client_id = p_user_id
             AND cr.status = 'active'
             AND get_enterprise_root_manager_id(cr.manager_id) = v_root
         )
      THEN RETURN TRUE; END IF;
    END IF;
  END IF;

  RETURN FALSE;
END;
$function$;

-- 4) 商户订单列表加「付款方式」筛选（现金 / 积分兑换）。
--    加默认参数必须整体重建，否则会多出一个同名重载导致 PostgREST 调用歧义。
DROP FUNCTION IF EXISTS public.manager_list_shop_orders(text[], text, timestamp with time zone, uuid, integer, text[]);

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
    WHERE o.owner_manager_id_snapshot = ANY(v_owners)
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

GRANT EXECUTE ON FUNCTION public.manager_list_shop_orders(text[], text, timestamp with time zone, uuid, integer, text[], text) TO authenticated;

-- 5) 付款方式筛选的支撑索引
CREATE INDEX IF NOT EXISTS idx_orders_owner_paymode_created
  ON public.orders (owner_manager_id_snapshot, pay_mode, created_at DESC, id DESC)
  WHERE owner_manager_id_snapshot IS NOT NULL;