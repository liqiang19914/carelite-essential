-- 商户级商城设置（按企业根商户存一份；无行 = 沿用平台默认「展示平台严选」）
CREATE TABLE IF NOT EXISTS public.manager_shop_settings (
  root_manager_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  show_platform_products boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.manager_shop_settings IS
  '商户级商城设置，按企业根商户一行。无行视为默认值（展示平台严选），保证存量商户行为不变。';

-- 只经 SECURITY DEFINER RPC 访问：开启 RLS 且不建策略（与 manager_points_rules 一致）
ALTER TABLE public.manager_shop_settings ENABLE ROW LEVEL SECURITY;

-- 商户端：读自己企业的商城设置
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

  SELECT s.show_platform_products INTO v_show
  FROM public.manager_shop_settings s
  WHERE s.root_manager_id = v_root;

  RETURN jsonb_build_object('show_platform_products', COALESCE(v_show, true));
END;
$function$;

-- 商户端：企业管理员写自己企业的商城设置
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

  INSERT INTO public.manager_shop_settings (root_manager_id, show_platform_products, updated_at)
  VALUES (v_root, p_show_platform_products, now())
  ON CONFLICT (root_manager_id) DO UPDATE
    SET show_platform_products = EXCLUDED.show_platform_products,
        updated_at             = now();

  RETURN public.get_my_shop_settings();
END;
$function$;

-- 客户端：商城模块开放状态补上「是否展示平台严选」
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

  -- 未绑定商户的平台直客：积分兑换默认开放，平台严选照常展示
  IF v_root IS NULL THEN
    RETURN jsonb_build_object('points_exchange', true, 'show_platform_products', true);
  END IF;

  SELECT (g.grant_status = 'granted' AND g.is_enabled) INTO v_points
  FROM public.merchant_module_grants g
  WHERE g.manager_id = v_root AND g.module_key = 'points_exchange';

  SELECT s.show_platform_products INTO v_show
  FROM public.manager_shop_settings s
  WHERE s.root_manager_id = v_root;

  RETURN jsonb_build_object(
    'points_exchange',        COALESCE(v_points, false),
    'show_platform_products', COALESCE(v_show, true)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_my_shop_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_my_shop_settings(boolean) TO authenticated;