-- feature 149：服务端收口——客户数据三类可见性由「商户级总开关」改为「平台授权 + 角色特殊权限」
-- module_key → 角色权限码映射：view_health_records→view_health_records，
-- view_health_insights→health_insights，view_conversations→conversations
CREATE OR REPLACE FUNCTION public.module_open_for_client(p_client_id uuid, p_module_key text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.client_relations cr
    JOIN public.merchant_module_grants g
      ON g.manager_id = public.get_enterprise_root_manager_id(cr.manager_id)
     AND g.module_key = p_module_key
     AND g.grant_status = 'granted'
     -- 数据类模块不再看商户级总开关（已由角色特殊权限逐人判断）；商城类模块仍需商户自行开启
     AND (
       g.is_enabled = true
       OR p_module_key IN ('view_health_records', 'view_health_insights', 'view_conversations')
     )
    WHERE cr.client_id = p_client_id
      AND cr.status = 'active'
      AND (
        cr.manager_id = (SELECT auth.uid())
        OR public.is_enterprise_member_for_admin(cr.manager_id, (SELECT auth.uid()))
      )
  )
  AND CASE p_module_key
        WHEN 'view_health_records'
          THEN public.has_enterprise_permission('view_health_records', (SELECT auth.uid()))
        WHEN 'view_health_insights'
          THEN public.has_enterprise_permission('health_insights', (SELECT auth.uid()))
        WHEN 'view_conversations'
          THEN public.has_enterprise_permission('conversations', (SELECT auth.uid()))
        ELSE true
      END;
$function$;

-- 商户端读取模块状态：数据类模块的 open = 平台已授权 AND 当前登录人角色已勾选
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

-- 商户级开关只保留商城类模块；数据类模块改由角色权限决定，旧客户端调用给出可执行的中文说明
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
  IF p_module_key NOT IN ('shop_order_lifecycle', 'points_exchange') THEN
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