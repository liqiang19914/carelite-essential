-- 平台自有商户（is_platform_root）对全部商城/企微模块默认开放。
-- 幂等：CREATE OR REPLACE，无 DML。

CREATE OR REPLACE FUNCTION public.get_my_merchant_module_state(p_module_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root             uuid;
  v_is_platform_root boolean;
  v_granted          boolean := false;
  v_enabled          boolean := false;
  v_permitted        boolean := true;
  v_is_data          boolean;
BEGIN
  IF p_module_key IS NULL
     OR p_module_key NOT IN ('points_exchange', 'stores', 'shop_order_lifecycle', 'view_health_records', 'view_health_insights', 'view_conversations', 'marketing_center', 'wecom_assistant_pro') THEN
    RAISE EXCEPTION '未知的商城模块' USING ERRCODE = '22023';
  END IF;

  v_root := public._my_root_manager_id();
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  -- 平台自有商户全模块默认开放：无需 merchant_module_grants 授权行
  SELECT COALESCE(m.is_platform_root, false)
    INTO v_is_platform_root
    FROM public.managers m
   WHERE m.id = v_root;
  IF COALESCE(v_is_platform_root, false) THEN
    RETURN jsonb_build_object(
      'granted', true,
      'enabled', true,
      'permitted', true,
      'open', true
    );
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

CREATE OR REPLACE FUNCTION public.wecom_pro_module_open(p_root uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    EXISTS (
      SELECT 1
      FROM public.managers m
      WHERE m.id = p_root
        AND COALESCE(m.is_platform_root, false)
    )
    OR EXISTS (
      SELECT 1
      FROM public.merchant_module_grants
      WHERE manager_id = p_root
        AND module_key = 'wecom_assistant_pro'
        AND grant_status = 'granted'
        AND COALESCE(is_enabled, false)
    );
$function$;

REVOKE ALL ON FUNCTION public.wecom_pro_module_open(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.wecom_pro_module_open(uuid) TO authenticated;