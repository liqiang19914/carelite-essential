-- 门店模块：平台授权白名单补 'stores'
CREATE OR REPLACE FUNCTION public.admin_set_merchant_module_grant(p_manager_id uuid, p_module_key text, p_granted boolean, p_notes text DEFAULT NULL::text)
 RETURNS merchant_module_grants
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.merchant_module_grants;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '只有平台管理员可以调整商户模块授权' USING ERRCODE = '42501';
  END IF;
  IF p_module_key NOT IN ('shop_order_lifecycle', 'points_exchange', 'view_health_records', 'view_health_insights', 'view_conversations', 'stores') THEN
    RAISE EXCEPTION '未知的模块' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.managers WHERE id = p_manager_id) THEN
    RAISE EXCEPTION '找不到该商户' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.merchant_module_grants (
    manager_id, module_key, grant_status, is_enabled, granted_by, notes
  ) VALUES (
    p_manager_id, p_module_key,
    CASE WHEN COALESCE(p_granted, false) THEN 'granted' ELSE 'revoked' END,
    false, v_uid, p_notes
  )
  ON CONFLICT (manager_id, module_key) DO UPDATE
  SET grant_status = CASE WHEN COALESCE(p_granted, false) THEN 'granted' ELSE 'revoked' END,
      is_enabled   = CASE WHEN COALESCE(p_granted, false)
                          THEN public.merchant_module_grants.is_enabled
                          ELSE false END,
      granted_by   = v_uid,
      granted_at   = now(),
      notes        = COALESCE(p_notes, public.merchant_module_grants.notes),
      updated_at   = now()
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

-- 门店模块：商户开关白名单补 'stores'
CREATE OR REPLACE FUNCTION public.set_my_merchant_module_enabled(p_module_key text, p_enabled boolean)
 RETURNS merchant_module_grants
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_root uuid := public._my_root_manager_id();
  v_row  public.merchant_module_grants;
BEGIN
  IF v_root IS NULL THEN
    RAISE EXCEPTION '只有商户账号可以设置商城模块' USING ERRCODE = '42501';
  END IF;
  IF p_module_key IN ('view_health_records', 'view_health_insights', 'view_conversations') THEN
    RAISE EXCEPTION '客户数据的查看权限已改为按角色授予，请到「企业中心 → 角色权限」里为对应角色勾选' USING ERRCODE = '22023';
  END IF;
  IF p_module_key NOT IN ('shop_order_lifecycle', 'points_exchange', 'stores') THEN
    RAISE EXCEPTION '未知的模块' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_module_grants
  WHERE manager_id = v_root AND module_key = p_module_key
  FOR UPDATE;

  IF v_row.id IS NULL OR v_row.grant_status <> 'granted' THEN
    RAISE EXCEPTION '平台尚未为你开放该模块，请联系平台运营' USING ERRCODE = '42501';
  END IF;

  UPDATE public.merchant_module_grants
  SET is_enabled = COALESCE(p_enabled, false), updated_at = now()
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;