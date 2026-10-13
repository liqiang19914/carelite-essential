-- 保存短信通道：切换服务商时旧 Secret 属于旧服务商，必须重新填写，不可沿用
CREATE OR REPLACE FUNCTION public.save_my_sms_channel(
  p_provider text,
  p_access_key_id text,
  p_access_key_secret text,
  p_sign_name text,
  p_template_code text,
  p_code_expiry integer,
  p_tencent_sdk_app_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_provider text;
  v_akid text;
  v_sign text;
  v_template text;
  v_expiry integer;
  v_secret text;
  v_old_provider text;
  v_sdk text;
  v_id uuid;
  v_revision uuid;
BEGIN
  IF NOT public.is_enterprise_admin(auth.uid()) THEN
    RAISE EXCEPTION '仅企业管理员可配置短信通道' USING ERRCODE = '42501';
  END IF;

  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  v_provider := btrim(COALESCE(p_provider, ''));
  IF v_provider NOT IN ('aliyun','tencent') THEN
    RAISE EXCEPTION '请选择短信服务商' USING ERRCODE = 'P0002';
  END IF;

  v_sign := btrim(COALESCE(p_sign_name, ''));
  IF char_length(v_sign) < 1 OR char_length(v_sign) > 20 THEN
    RAISE EXCEPTION '短信签名长度需在 1-20 个字符之间' USING ERRCODE = 'P0002';
  END IF;

  v_akid := btrim(COALESCE(p_access_key_id, ''));
  IF v_akid = '' THEN
    RAISE EXCEPTION '请填写 AccessKey ID' USING ERRCODE = 'P0002';
  END IF;

  v_template := btrim(COALESCE(p_template_code, ''));
  IF v_template = '' THEN
    RAISE EXCEPTION '请填写验证码模板编号' USING ERRCODE = 'P0002';
  END IF;

  v_expiry := COALESCE(p_code_expiry, 5);
  IF v_expiry < 1 OR v_expiry > 30 THEN
    RAISE EXCEPTION '验证码有效期需在 1-30 分钟之间' USING ERRCODE = 'P0002';
  END IF;

  v_sdk := btrim(COALESCE(p_tencent_sdk_app_id, ''));
  IF v_provider = 'tencent' AND v_sdk = '' THEN
    RAISE EXCEPTION '腾讯云短信需填写 SmsSdkAppId' USING ERRCODE = 'P0002';
  END IF;

  -- Secret 语义：留空=保留原值；新建或切换服务商时必填
  SELECT provider, access_key_secret INTO v_old_provider, v_secret
  FROM public.manager_sms_configs
  WHERE root_manager_id = v_root;

  IF (p_access_key_secret IS NULL OR btrim(p_access_key_secret) = '') THEN
    IF v_secret IS NULL OR v_secret = '' THEN
      RAISE EXCEPTION '请填写 AccessKey Secret' USING ERRCODE = 'P0002';
    END IF;
    IF v_old_provider IS NOT NULL AND v_old_provider <> v_provider THEN
      RAISE EXCEPTION '切换服务商后需重新填写 AccessKey Secret' USING ERRCODE = 'P0002';
    END IF;
  ELSE
    v_secret := btrim(p_access_key_secret);
  END IF;

  v_revision := gen_random_uuid();

  INSERT INTO public.manager_sms_configs (
    root_manager_id, provider, access_key_id, access_key_secret,
    sign_name, template_code, code_expiry, tencent_sdk_app_id,
    status, review_note, config_revision
  )
  VALUES (
    v_root, v_provider, v_akid, v_secret,
    v_sign, v_template, v_expiry,
    NULLIF(v_sdk, ''),
    'pending', NULL, v_revision
  )
  ON CONFLICT (root_manager_id) DO UPDATE
    SET provider = EXCLUDED.provider,
        access_key_id = EXCLUDED.access_key_id,
        access_key_secret = EXCLUDED.access_key_secret,
        sign_name = EXCLUDED.sign_name,
        template_code = EXCLUDED.template_code,
        code_expiry = EXCLUDED.code_expiry,
        tencent_sdk_app_id = EXCLUDED.tencent_sdk_app_id,
        status = 'pending',
        review_note = NULL,
        config_revision = EXCLUDED.config_revision,
        updated_at = now()
  RETURNING id, config_revision INTO v_id, v_revision;

  RETURN jsonb_build_object('id', v_id, 'config_revision', v_revision, 'status', 'pending');
END;
$function$;

REVOKE ALL ON FUNCTION public.save_my_sms_channel(text, text, text, text, text, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_my_sms_channel(text, text, text, text, text, integer, text) TO authenticated;