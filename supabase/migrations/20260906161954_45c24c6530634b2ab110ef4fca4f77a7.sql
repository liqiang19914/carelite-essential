-- 修正 list_my_accessible_stores：跨店枚举的企业根须从调用者的 owner/admin 成员关系推导
-- （纯门店管理员为普通 user 档案，get_enterprise_root_manager_id 对其返回 NULL，导致跨店分支永不命中）
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
    WHERE m.user_id = v_uid AND m.status = 'active' AND m.role IN ('owner','admin')
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

GRANT EXECUTE ON FUNCTION public.list_my_accessible_stores() TO authenticated;
REVOKE EXECUTE ON FUNCTION public.list_my_accessible_stores() FROM PUBLIC, anon;