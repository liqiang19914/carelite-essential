-- 275: OEM 商户（已开通独立小程序的根商户）商城强制不展示平台严选
CREATE OR REPLACE FUNCTION public.is_oem_root(p_root uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.manager_miniprograms mm
    WHERE mm.manager_id = p_root AND mm.is_enabled = TRUE
  );
$function$;

REVOKE ALL ON FUNCTION public.is_oem_root(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_oem_root(uuid) TO authenticated;

-- 商户端读取：OEM 商户恒返回关闭，并带 oem_locked 供前端隐藏开关
CREATE OR REPLACE FUNCTION public.get_my_shop_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_root uuid;
  v_show boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT CASE WHEN p.parent_manager_id IS NULL THEN p.id ELSE p.parent_manager_id END
    INTO v_root
    FROM public.profiles p
    WHERE p.id = v_uid AND p.role = 'manager';

  IF v_root IS NULL THEN
    RAISE EXCEPTION '仅商户可查看商城设置' USING ERRCODE = '42501';
  END IF;

  IF public.is_oem_root(v_root) THEN
    RETURN jsonb_build_object('show_platform_products', false, 'oem_locked', true);
  END IF;

  SELECT s.show_platform_products INTO v_show
  FROM public.manager_shop_settings s
  WHERE s.root_manager_id = v_root;

  RETURN jsonb_build_object('show_platform_products', COALESCE(v_show, true), 'oem_locked', false);
END;
$function$;

-- 商户端保存：OEM 商户无论传什么一律落为关闭
CREATE OR REPLACE FUNCTION public.save_my_shop_settings(p_show_platform_products boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid      uuid := auth.uid();
  v_root     uuid;
  v_is_admin boolean;
  v_forced   boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;
  IF p_show_platform_products IS NULL THEN
    RAISE EXCEPTION '请指定是否展示平台严选商品' USING ERRCODE = '22023';
  END IF;

  SELECT (p.parent_manager_id IS NULL OR p.sub_role = 'admin') INTO v_is_admin
  FROM public.profiles p
  WHERE p.id = v_uid AND p.role = 'manager';

  IF v_is_admin IS NOT TRUE THEN
    RAISE EXCEPTION '仅企业管理员可修改商城设置' USING ERRCODE = '42501';
  END IF;

  SELECT CASE WHEN p.parent_manager_id IS NULL THEN p.id ELSE p.parent_manager_id END
    INTO v_root
    FROM public.profiles p
    WHERE p.id = v_uid;

  v_forced := public.is_oem_root(v_root);

  INSERT INTO public.manager_shop_settings (root_manager_id, show_platform_products, updated_at)
  VALUES (v_root, CASE WHEN v_forced THEN false ELSE p_show_platform_products END, now())
  ON CONFLICT (root_manager_id) DO UPDATE
    SET show_platform_products = CASE WHEN v_forced THEN false ELSE EXCLUDED.show_platform_products END,
        updated_at             = now();

  RETURN public.get_my_shop_settings();
END;
$function$;

-- C 端模块状态：绑定 OEM 商户的用户恒不展示平台严选
CREATE OR REPLACE FUNCTION public.get_my_shop_modules()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root   uuid;
  v_points boolean;
  v_show   boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  v_root := public._my_bound_root_manager_id();

  IF v_root IS NULL THEN
    RETURN jsonb_build_object('points_exchange', true, 'show_platform_products', true);
  END IF;

  SELECT (g.grant_status = 'granted' AND g.is_enabled) INTO v_points
  FROM public.merchant_module_grants g
  WHERE g.manager_id = v_root AND g.module_key = 'points_exchange';

  IF public.is_oem_root(v_root) THEN
    RETURN jsonb_build_object(
      'points_exchange',        COALESCE(v_points, false),
      'show_platform_products', false
    );
  END IF;

  SELECT s.show_platform_products INTO v_show
  FROM public.manager_shop_settings s
  WHERE s.root_manager_id = v_root;

  RETURN jsonb_build_object(
    'points_exchange',        COALESCE(v_points, false),
    'show_platform_products', COALESCE(v_show, true)
  );
END;
$function$;

-- 存量回填：OEM 商户已开启的开关一律关闭
UPDATE public.manager_shop_settings s
SET show_platform_products = false,
    updated_at             = now()
WHERE s.show_platform_products = true
  AND public.is_oem_root(s.root_manager_id);