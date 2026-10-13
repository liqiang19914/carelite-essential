-- 249 审查修复 1：商城模块开关仅企业主/企业管理员可操作，且账号未禁用
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
  IF p_module_key NOT IN ('shop_order_lifecycle', 'points_exchange', 'stores') THEN
    RAISE EXCEPTION '未知的模块' USING ERRCODE = '22023';
  END IF;

  -- 商城模块是整店开关：只有企业主或企业管理员可以操作，普通员工不能影响企业级入口
  SELECT parent_manager_id, sub_role, COALESCE(is_disabled, false)
    INTO v_parent, v_sub_role, v_disabled
    FROM public.profiles
   WHERE id = auth.uid();
  IF v_disabled OR NOT (v_parent IS NULL OR v_sub_role = 'admin') THEN
    RAISE EXCEPTION '只有企业主或企业管理员可以设置商城模块' USING ERRCODE = '42501';
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

REVOKE ALL ON FUNCTION public.set_my_merchant_module_enabled(text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_my_merchant_module_enabled(text, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_my_merchant_module_enabled(text, boolean) TO authenticated;

-- 249 审查修复 2：企业改名校验账号角色与禁用状态（禁用企业主的残留登录态不能改名）
CREATE OR REPLACE FUNCTION public.save_my_enterprise_name(p_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_enterprise_id uuid;
  v_role text;
  v_disabled boolean;
  v_old_name text;
  v_brand text;
  v_brand_followed boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION '企业名称不能为空' USING ERRCODE = '22023';
  END IF;
  IF length(btrim(p_name)) < 2 OR length(btrim(p_name)) > 40 THEN
    RAISE EXCEPTION '企业名称长度需在 2 到 40 个字之间' USING ERRCODE = '22023';
  END IF;

  SELECT enterprise_id, role, COALESCE(is_disabled, false)
    INTO v_enterprise_id, v_role, v_disabled
    FROM profiles WHERE id = v_uid;
  IF v_enterprise_id IS NULL THEN
    RAISE EXCEPTION '您还没有企业，无法修改企业名称' USING ERRCODE = '42501';
  END IF;
  IF v_role <> 'manager' OR v_disabled THEN
    RAISE EXCEPTION '仅企业主可修改企业名称' USING ERRCODE = '42501';
  END IF;

  PERFORM 1 FROM enterprises
   WHERE id = v_enterprise_id AND owner_profile_id = v_uid AND status = 'active'
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '仅企业主可修改企业名称' USING ERRCODE = '42501';
  END IF;

  SELECT name INTO v_old_name FROM enterprises WHERE id = v_enterprise_id;
  UPDATE enterprises SET name = btrim(p_name), updated_at = now() WHERE id = v_enterprise_id;

  -- 对外品牌名联动：仅当已有 OEM 配置、且品牌名未独立设置（为空或等于旧企业名）时跟随
  SELECT brand_name INTO v_brand FROM manager_miniprograms WHERE manager_id = v_uid FOR UPDATE;
  IF FOUND THEN
    IF v_brand IS NULL OR v_brand = '' OR v_brand = v_old_name THEN
      UPDATE manager_miniprograms SET brand_name = btrim(p_name) WHERE manager_id = v_uid;
      v_brand_followed := true;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'enterprise_id', v_enterprise_id,
    'name', btrim(p_name),
    'brand_followed', v_brand_followed
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.save_my_enterprise_name(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_my_enterprise_name(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.save_my_enterprise_name(text) TO authenticated;

-- 249 审查修复 3：匿名权限回收基线补齐
REVOKE ALL ON FUNCTION public.get_my_enterprise_profile() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_enterprise_profile() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_enterprise_profile() TO authenticated;

REVOKE EXECUTE ON FUNCTION public.admin_list_manager_oem_configs() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_list_manager_oem_configs() FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_list_manager_oem_configs() TO authenticated;