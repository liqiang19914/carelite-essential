-- 体重单位设置：读放宽到任意本企业成员（普通员工在称重页也要按商户口径显示），保存仍仅超管
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
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是企业成员' USING ERRCODE = '42501';
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
REVOKE ALL ON FUNCTION public.get_merchant_weight_unit_settings() FROM PUBLIC, anon;
