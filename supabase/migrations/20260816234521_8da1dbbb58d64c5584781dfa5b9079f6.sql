-- 修复1：save_my_sms_config 仅企业管理员（boss 或 sub_role=admin，且未停用）可配置
CREATE OR REPLACE FUNCTION public.save_my_sms_config(p_sign_name text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_sign text;
  v_id uuid;
BEGIN
  IF NOT public.is_enterprise_admin(auth.uid()) THEN
    RAISE EXCEPTION '仅企业管理员可配置短信签名' USING ERRCODE = '42501';
  END IF;

  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  v_sign := btrim(COALESCE(p_sign_name, ''));
  IF char_length(v_sign) < 1 OR char_length(v_sign) > 20 THEN
    RAISE EXCEPTION '签名长度需在 1-20 个字符之间' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.manager_sms_configs (root_manager_id, sign_name, status, review_note)
  VALUES (v_root, v_sign, 'pending', NULL)
  ON CONFLICT (root_manager_id) DO UPDATE
    SET sign_name = EXCLUDED.sign_name,
        status = 'pending',
        review_note = NULL,
        updated_at = now()
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'sign_name', v_sign, 'status', 'pending');
END;
$function$;

REVOKE ALL ON FUNCTION public.save_my_sms_config(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_my_sms_config(text) TO authenticated;

-- 修复2：审核绑定签名内容（p_expected_sign_name），防止审核间隙商户改签名导致批错版本
CREATE OR REPLACE FUNCTION public.admin_review_sms_config(
  p_root_manager_id uuid,
  p_status text,
  p_expected_sign_name text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_status text;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  IF p_status NOT IN ('approved','rejected','pending') THEN
    RAISE EXCEPTION '不支持的状态' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.manager_sms_configs
     SET status = p_status,
         review_note = btrim(COALESCE(p_note, '')),
         updated_at = now()
   WHERE root_manager_id = p_root_manager_id
     AND sign_name = p_expected_sign_name
   RETURNING status INTO v_status;

  IF v_status IS NULL THEN
    RAISE EXCEPTION '该商户已修改签名，请刷新后重新审核' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('root_manager_id', p_root_manager_id, 'status', v_status);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_review_sms_config(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_review_sms_config(uuid, text, text, text) TO authenticated;