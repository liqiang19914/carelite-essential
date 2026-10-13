-- 商户端读自己企业的模块状态。
-- 不让前端裸查表靠行级安全兜底：授权行挂在「根商户」上，员工子账号必须经
-- _my_root_manager_id() 归一后再按 manager_id 显式过滤，业务边界要写在服务端。
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
     OR p_module_key NOT IN ('points_exchange', 'shop_order_lifecycle') THEN
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

REVOKE ALL ON FUNCTION public.get_my_merchant_module_state(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_merchant_module_state(text) TO authenticated;