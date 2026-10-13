-- 对齐档案授权设置的门禁：读也走企业超级管理员权限，而非内容成员资格
CREATE OR REPLACE FUNCTION public.get_merchant_weight_unit_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_row public.merchant_weight_unit_settings%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RAISE EXCEPTION '仅企业超级管理员可配置体重单位设置' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_weight_unit_settings
  WHERE root_manager_id = v_root;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('weight_unit_mode', 'user_choice');
  END IF;

  RETURN jsonb_build_object('weight_unit_mode', v_row.weight_unit_mode);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_merchant_weight_unit_settings() TO authenticated;

-- 保存补上商户根空值防御，避免非商户触发 NOT NULL 违反
CREATE OR REPLACE FUNCTION public.save_merchant_weight_unit_settings(
  p_weight_unit_mode text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RAISE EXCEPTION '只有企业超级管理员可以修改体重单位设置' USING ERRCODE = '42501';
  END IF;
  IF p_weight_unit_mode IS NULL OR p_weight_unit_mode NOT IN ('jin','kg','user_choice') THEN
    RAISE EXCEPTION '无效的体重单位模式' USING ERRCODE = '22023';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.merchant_weight_unit_settings
    (root_manager_id, weight_unit_mode, updated_by, updated_at)
  VALUES (v_root, p_weight_unit_mode, v_uid, now())
  ON CONFLICT (root_manager_id) DO UPDATE
    SET weight_unit_mode = EXCLUDED.weight_unit_mode,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object('success', true);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.save_merchant_weight_unit_settings(text) TO authenticated;