-- 门店体系批次审查修复：P1 跨店核销口径统一 + P2 跨店资格限定本企业/手机号脱敏兜底/四函数 REVOKE
-- P1: verify_offline_store_order_by_code 移除 cross_store 放行分支——跨店只扩读不扩写，写口径与 verify_offline_store_order 一致（本店成员或 _can_admin_store）
CREATE OR REPLACE FUNCTION public.verify_offline_store_order_by_code(p_code text, p_store_id uuid DEFAULT NULL::uuid)
 RETURNS json
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

-- P2: get_store_workbench_scope——企业根回退推导加确定性排序；owner/admin 成员资格 EXISTS 限定本企业根，防止在别的企业任店管理员者在本企业获得跨店读
CREATE OR REPLACE FUNCTION public.get_store_workbench_scope(p_store_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_root uuid;
  v_store_root uuid;
  v_cross boolean;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('role', null::text, 'cross_store', false);
  END IF;
  v_role := public.get_store_member_role(p_store_id);
  IF v_role IS NOT NULL THEN
    RETURN jsonb_build_object('role', v_role, 'cross_store', false);
  END IF;
  SELECT s.root_manager_id INTO v_store_root FROM public.stores s WHERE s.id = p_store_id;
  IF v_store_root IS NULL THEN
    RETURN jsonb_build_object('role', null::text, 'cross_store', false);
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    SELECT s.root_manager_id INTO v_root
    FROM public.store_members m
    JOIN public.stores s ON s.id = m.store_id
    WHERE m.user_id = v_uid AND m.status = 'active' AND m.role IN ('owner','admin')
    ORDER BY s.root_manager_id
    LIMIT 1;
  END IF;
  IF v_root IS NULL OR v_root <> v_store_root THEN
    RETURN jsonb_build_object('role', null::text, 'cross_store', false);
  END IF;
  IF public.is_enterprise_admin(v_uid) THEN
    RETURN jsonb_build_object('role', null::text, 'cross_store', true);
  END IF;
  SELECT bs.admin_cross_store_view INTO v_cross
  FROM public.merchant_store_binding_settings bs
  WHERE bs.root_manager_id = v_root;
  IF coalesce(v_cross, false) AND EXISTS (
    SELECT 1 FROM public.store_members m
    JOIN public.stores s ON s.id = m.store_id
    WHERE m.user_id = v_uid AND m.status = 'active' AND m.role IN ('owner','admin')
      AND s.root_manager_id = v_root
  ) THEN
    RETURN jsonb_build_object('role', null::text, 'cross_store', true);
  END IF;
  RETURN jsonb_build_object('role', null::text, 'cross_store', false);
END;
$function$;

-- P2: list_my_accessible_stores——同上：跨店枚举的企业根推导与成员资格检查都限定本企业根
CREATE OR REPLACE FUNCTION public.list_my_accessible_stores()
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_cross boolean;
  v_items json;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    SELECT s.root_manager_id INTO v_root
    FROM public.store_members m
    JOIN public.stores s ON s.id = m.store_id
    WHERE m.user_id = v_uid AND m.status = 'active' AND m.role IN ('owner','admin')
    ORDER BY s.root_manager_id
    LIMIT 1;
  END IF;

  IF v_root IS NOT NULL AND public.is_enterprise_admin(v_uid) THEN
    SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
    FROM (
      SELECT s.id, s.short_code, s.name, s.phone, s.status, s.root_manager_id,
             s.receipt_qr_url, s.payment_merchant_no, s.created_source,
             s.address, s.storefront_image_url, s.disabled_at, s.created_at,
             COALESCE(public.get_store_member_role(s.id), 'admin') AS my_role
      FROM public.stores s
      WHERE s.root_manager_id = v_root
    ) t;
    RETURN json_build_object('items', COALESCE(v_items, '[]'::json));
  END IF;

  IF v_root IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.merchant_store_binding_settings bs
    WHERE bs.root_manager_id = v_root AND bs.admin_cross_store_view = true
  ) AND EXISTS (
    SELECT 1 FROM public.store_members m
    JOIN public.stores s ON s.id = m.store_id
    WHERE m.user_id = v_uid AND m.status = 'active' AND m.role IN ('owner','admin')
      AND s.root_manager_id = v_root
  ) THEN
    SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
    FROM (
      SELECT s.id, s.short_code, s.name, s.phone, s.status, s.root_manager_id,
             s.receipt_qr_url, s.payment_merchant_no, s.created_source,
             s.address, s.storefront_image_url, s.disabled_at, s.created_at,
             COALESCE(public.get_store_member_role(s.id), 'clerk') AS my_role
      FROM public.stores s
      WHERE s.root_manager_id = v_root
    ) t;
    RETURN json_build_object('items', COALESCE(v_items, '[]'::json));
  END IF;

  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT s.id, s.short_code, s.name, s.phone, s.status, s.root_manager_id,
           s.receipt_qr_url, s.payment_merchant_no, s.created_source,
           s.address, s.storefront_image_url, s.disabled_at, s.created_at,
           m.role AS my_role
    FROM public.store_members m
    JOIN public.stores s ON s.id = m.store_id
    WHERE m.user_id = v_uid AND m.status = 'active'
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::json));
END;
$function$;

-- P2: get_store_visible_phone——店员分支对任意格式兜底掩码，绝不因格式把明文漏给店员（管理员分支不变）
CREATE OR REPLACE FUNCTION public.get_store_visible_phone(p_store_id uuid, p_phone text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_scope jsonb;
  v_digits text;
BEGIN
  IF v_uid IS NULL OR p_phone IS NULL THEN
    RETURN p_phone;
  END IF;
  IF public.is_admin(v_uid) THEN
    RETURN p_phone;
  END IF;
  v_role := public.get_store_member_role(p_store_id);
  IF v_role IN ('owner','admin') THEN
    RETURN p_phone;
  END IF;
  v_scope := public.get_store_workbench_scope(p_store_id);
  IF (v_scope->>'cross_store')::boolean THEN
    RETURN p_phone;
  END IF;
  v_digits := regexp_replace(p_phone, '[^0-9]', '', 'g');
  IF length(v_digits) = 11 THEN
    RETURN substr(v_digits, 1, 3) || '****' || substr(v_digits, 8);
  END IF;
  IF length(v_digits) >= 6 THEN
    RETURN substr(v_digits, 1, 2) || '****' || substr(v_digits, length(v_digits) - 3);
  END IF;
  RETURN '******';
END;
$function$;

-- P2: 四个客户端函数此前只 GRANT authenticated 未收口 PUBLIC/anon（幂等 REVOKE；既有 authenticated GRANT 保持不动）
REVOKE ALL ON FUNCTION public.bind_user_to_store(uuid, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_store_binding_customers(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_store_sales_overview(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_store_members(uuid) FROM PUBLIC, anon;

-- 幂等授权：与既有授权结构一致
GRANT EXECUTE ON FUNCTION public.verify_offline_store_order_by_code(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_store_workbench_scope(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_store_workbench_scope(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_my_accessible_stores() TO authenticated;
REVOKE EXECUTE ON FUNCTION public.list_my_accessible_stores() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_store_visible_phone(uuid, text) FROM PUBLIC, anon, authenticated;