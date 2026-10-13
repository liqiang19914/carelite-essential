-- 246：get_my_merchant_module_state 白名单补 stores，商户端才能读到门店模块授权状态
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
  v_permitted boolean := true;
  v_is_data   boolean;
BEGIN
  IF p_module_key IS NULL
     OR p_module_key NOT IN ('points_exchange', 'stores', 'shop_order_lifecycle', 'view_health_records', 'view_health_insights', 'view_conversations') THEN
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

  v_granted := COALESCE(v_granted, false);
  v_enabled := COALESCE(v_enabled, false);
  v_is_data := p_module_key IN ('view_health_records', 'view_health_insights', 'view_conversations');

  IF v_is_data THEN
    v_permitted := public.has_enterprise_permission(
      CASE p_module_key
        WHEN 'view_health_records'  THEN 'view_health_records'
        WHEN 'view_health_insights' THEN 'health_insights'
        ELSE 'conversations'
      END,
      auth.uid()
    );
  END IF;

  RETURN jsonb_build_object(
    'granted', v_granted,
    'enabled', v_enabled,
    'permitted', COALESCE(v_permitted, false),
    'open', CASE
              WHEN v_is_data THEN v_granted AND COALESCE(v_permitted, false)
              ELSE v_granted AND v_enabled
            END
  );
END;
$function$;