-- 修正 get_store_workbench_scope：非成员路径的企业根须从调用者的 owner/admin 成员关系推导
-- （纯门店管理员为普通 user 档案，get_enterprise_root_manager_id 返回 NULL，导致跨店读对非成员店恒拒绝）
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
    WHERE m.user_id = v_uid AND m.status = 'active' AND m.role IN ('owner','admin')
  ) THEN
    RETURN jsonb_build_object('role', null::text, 'cross_store', true);
  END IF;
  RETURN jsonb_build_object('role', null::text, 'cross_store', false);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_store_workbench_scope(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_store_workbench_scope(uuid) FROM PUBLIC, anon;