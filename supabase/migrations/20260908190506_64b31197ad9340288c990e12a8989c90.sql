-- 平台自有商户（is_platform_root）模块开关自洽化：默认授予+开启，但尊重手动关闭。
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

  v_is_data := p_module_key IN ('view_health_records', 'view_health_insights', 'view_conversations');

  SELECT COALESCE(m.is_platform_root, false)
    INTO v_is_platform_root
    FROM public.managers m
   WHERE m.id = v_root;

  IF COALESCE(v_is_platform_root, false) THEN
    -- 平台自有商户：默认授予 + 开启，但尊重商户在开关页的手动关闭（无授权行按开启处理）
    v_granted := true;
    v_permitted := true;
    SELECT COALESCE(g.is_enabled, true)
      INTO v_enabled
      FROM public.merchant_module_grants g
     WHERE g.manager_id = v_root
       AND g.module_key = p_module_key;
    v_enabled := COALESCE(v_enabled, true);
  ELSE
    SELECT (g.grant_status = 'granted'), COALESCE(g.is_enabled, false)
    INTO v_granted, v_enabled
    FROM public.merchant_module_grants g
    WHERE g.manager_id = v_root
      AND g.module_key = p_module_key;

    v_granted := COALESCE(v_granted, false);
    v_enabled := COALESCE(v_enabled, false);

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

CREATE OR REPLACE FUNCTION public.set_my_merchant_module_enabled(p_module_key text, p_enabled boolean)
RETURNS merchant_module_grants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root uuid := public._my_root_manager_id();
  v_row  public.merchant_module_grants;
  v_parent uuid;
  v_sub_role text;
  v_disabled boolean;
BEGIN
  IF v_root IS NULL THEN
    RAISE EXCEPTION '只有商户账号可以设置商城模块' USING ERRCODE = '42501';
  END IF;
  IF p_module_key IN ('view_health_records', 'view_health_insights', 'view_conversations') THEN
    RAISE EXCEPTION '客户数据的查看权限已改为按角色授予，请到「企业中心 → 角色权限」里为对应角色勾选' USING ERRCODE = '22023';
  END IF;
  IF p_module_key NOT IN ('shop_order_lifecycle', 'points_exchange', 'stores', 'marketing_center', 'wecom_assistant_pro') THEN
    RAISE EXCEPTION '未知的模块' USING ERRCODE = '22023';
  END IF;

  SELECT parent_manager_id, sub_role, COALESCE(is_disabled, false)
    INTO v_parent, v_sub_role, v_disabled
    FROM public.profiles
   WHERE id = auth.uid();
  IF v_disabled OR NOT (v_parent IS NULL OR v_sub_role = 'admin') THEN
    RAISE EXCEPTION '只有企业主或企业管理员可以设置商城模块' USING ERRCODE = '42501';
  END IF;

  -- 平台自有商户：跳过「平台尚未开放」闸门，自动授予并直接 toggle 开关
  IF EXISTS (
    SELECT 1 FROM public.managers m
    WHERE m.id = v_root AND COALESCE(m.is_platform_root, false)
  ) THEN
    INSERT INTO public.merchant_module_grants (
      manager_id, module_key, grant_status, is_enabled, granted_by, notes
    ) VALUES (
      v_root, p_module_key, 'granted', COALESCE(p_enabled, false), auth.uid(), NULL
    )
    ON CONFLICT (manager_id, module_key) DO UPDATE
    SET grant_status = 'granted',
        is_enabled   = COALESCE(p_enabled, false),
        updated_at   = now()
    RETURNING * INTO v_row;
    RETURN v_row;
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