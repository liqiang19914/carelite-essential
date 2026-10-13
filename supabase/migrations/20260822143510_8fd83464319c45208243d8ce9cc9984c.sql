CREATE OR REPLACE FUNCTION public.list_store_granted_products(p_store_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_store public.stores%ROWTYPE;
  v_root UUID;
  v_items JSON;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_store FROM public.stores WHERE id = p_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '门店不存在' USING ERRCODE = '22023';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS DISTINCT FROM v_store.root_manager_id
     AND v_store.operator_user_id IS DISTINCT FROM v_uid
     AND NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '你没有查看这家门店的权限' USING ERRCODE = '42501';
  END IF;

  SELECT json_agg(t ORDER BY t.updated_at DESC) INTO v_items
  FROM (
    SELECT g.product_id, g.is_enabled, g.updated_at
    FROM public.store_product_grants g
    WHERE g.store_id = v_store.id
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;