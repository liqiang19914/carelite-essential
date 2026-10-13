CREATE OR REPLACE FUNCTION public.get_my_merchant_module_state(p_module_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_root      uuid;
  v_granted   boolean := false;
  v_enabled   boolean := false;
BEGIN
  IF p_module_key IS NULL
     OR p_module_key NOT IN ('points_exchange', 'shop_order_lifecycle', 'view_health_records', 'view_health_insights', 'view_conversations') THEN
    RAISE EXCEPTION '未知的商城模块' USING ERRCODE = '22023';
  END IF;

  v_root := public._my_root_manager_id();
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  SELECT (g.grant_status = 'granted'), COALESCE(g.is_enabled, false)
  INTO v_granted, v_enabled
  FROM public.merchant_module_grants g
  WHERE g.manager_id = v_root
    AND g.module_key = p_module_key;

  RETURN jsonb_build_object(
    'granted', COALESCE(v_granted, false),
    'enabled', COALESCE(v_enabled, false),
    'open', COALESCE(v_granted, false) AND COALESCE(v_enabled, false)
  );
END;
$function$;

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
  IF p_module_key NOT IN ('shop_order_lifecycle', 'points_exchange', 'view_health_records', 'view_health_insights', 'view_conversations') THEN
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