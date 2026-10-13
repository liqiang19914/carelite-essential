-- 商户级体重单位设置：按企业根一行，控制客户端全站斤/公斤展示口径
CREATE TABLE IF NOT EXISTS public.merchant_weight_unit_settings (
  root_manager_id uuid PRIMARY KEY REFERENCES public.managers(id) ON DELETE CASCADE,
  weight_unit_mode text NOT NULL DEFAULT 'user_choice'
    CHECK (weight_unit_mode IN ('jin','kg','user_choice')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

COMMENT ON TABLE public.merchant_weight_unit_settings IS
  '商户级体重单位设置：root_manager_id 按企业根一行；jin=全局斤，kg=全局公斤，user_choice=用户自选（默认）';
COMMENT ON COLUMN public.merchant_weight_unit_settings.weight_unit_mode IS
  '客户端展示单位口径；jin/kg 全局固定，user_choice 保留用户斤/kg 开关';

ALTER TABLE public.merchant_weight_unit_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.merchant_weight_unit_settings FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_weight_unit_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_weight_unit_settings TO service_role;

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
  IF NOT public.is_active_enterprise_content_member(v_uid) THEN
    RAISE EXCEPTION '所属企业当前不可配置，请联系企业负责人或平台处理' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);

  SELECT * INTO v_row
  FROM public.merchant_weight_unit_settings
  WHERE root_manager_id = v_root;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('weight_unit_mode', 'user_choice');
  END IF;

  RETURN jsonb_build_object('weight_unit_mode', v_row.weight_unit_mode);
END;
$function$;

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

CREATE OR REPLACE FUNCTION public.get_public_weight_unit_settings(p_root_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row public.merchant_weight_unit_settings%ROWTYPE;
BEGIN
  IF p_root_manager_id IS NULL
     OR NOT public.is_public_enterprise_content_root(p_root_manager_id) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_weight_unit_settings
  WHERE root_manager_id = p_root_manager_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('weight_unit_mode', 'user_choice');
  END IF;

  RETURN jsonb_build_object('weight_unit_mode', v_row.weight_unit_mode);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_merchant_weight_unit_settings() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_merchant_weight_unit_settings() TO authenticated;
REVOKE ALL ON FUNCTION public.save_merchant_weight_unit_settings(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_merchant_weight_unit_settings(text) TO authenticated;
REVOKE ALL ON FUNCTION public.get_public_weight_unit_settings(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_weight_unit_settings(uuid) TO anon, authenticated;