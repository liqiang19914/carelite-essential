-- ============================================================================
-- 扩展 manager_sms_configs 为完整商户短信通道 + 保存/读取/审核 RPC
-- 归属 root_manager_id；密钥永不回传前端；审核绑定 config_revision 防批错版本。
-- ============================================================================

ALTER TABLE public.manager_sms_configs
  ADD COLUMN IF NOT EXISTS provider text,
  ADD COLUMN IF NOT EXISTS access_key_id text,
  ADD COLUMN IF NOT EXISTS access_key_secret text,
  ADD COLUMN IF NOT EXISTS template_code text,
  ADD COLUMN IF NOT EXISTS code_expiry integer,
  ADD COLUMN IF NOT EXISTS tencent_sdk_app_id text,
  ADD COLUMN IF NOT EXISTS config_revision uuid NOT NULL DEFAULT gen_random_uuid();

-- 历史仅有签名的记录不构成完整通道，统一转待补全
UPDATE public.manager_sms_configs
   SET status = 'pending',
       review_note = '请补全短信通道后重新提交审核'
 WHERE provider IS NULL;

ALTER TABLE public.manager_sms_configs
  DROP CONSTRAINT IF EXISTS manager_sms_configs_provider_check;
ALTER TABLE public.manager_sms_configs
  ADD CONSTRAINT manager_sms_configs_provider_check
  CHECK (provider IS NULL OR provider IN ('aliyun','tencent'));

ALTER TABLE public.manager_sms_configs
  DROP CONSTRAINT IF EXISTS manager_sms_configs_code_expiry_check;
ALTER TABLE public.manager_sms_configs
  ADD CONSTRAINT manager_sms_configs_code_expiry_check
  CHECK (code_expiry IS NULL OR (code_expiry >= 1 AND code_expiry <= 30));

-- 商户：读自己企业的短信通道（永不返回 Secret 明文）
CREATE OR REPLACE FUNCTION public.list_my_sms_config()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RETURN NULL::jsonb;
  END IF;

  RETURN (
    SELECT to_jsonb(c)
    FROM (
      SELECT id,
             root_manager_id,
             provider,
             access_key_id,
             (access_key_secret IS NOT NULL AND access_key_secret <> '') AS has_access_key_secret,
             sign_name,
             template_code,
             code_expiry,
             tencent_sdk_app_id,
             config_revision,
             status,
             review_note,
             created_at,
             updated_at
      FROM public.manager_sms_configs
      WHERE root_manager_id = v_root
    ) c
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_my_sms_config() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_sms_config() TO authenticated;

-- 商户：保存完整短信通道（仅企业管理员；Secret 留空=保留原值，新建必填；变更回退 pending 并刷新 revision）
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

  -- Secret 语义：留空=保留原值；新建时必填
  SELECT access_key_secret INTO v_secret
  FROM public.manager_sms_configs
  WHERE root_manager_id = v_root;

  IF (p_access_key_secret IS NULL OR btrim(p_access_key_secret) = '') THEN
    IF v_secret IS NULL OR v_secret = '' THEN
      RAISE EXCEPTION '请填写 AccessKey Secret' USING ERRCODE = 'P0002';
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

-- 平台：列出全部商户短信通道（掩码 AccessKey ID，永不返回 Secret）
CREATE OR REPLACE FUNCTION public.admin_list_sms_configs()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT c.id,
           c.root_manager_id,
           c.provider,
           CASE
             WHEN c.access_key_id IS NULL OR c.access_key_id = '' THEN NULL
             WHEN char_length(c.access_key_id) <= 6 THEN '******'
             ELSE left(c.access_key_id, 4) || '****' || right(c.access_key_id, 4)
           END AS access_key_id_masked,
           (c.access_key_secret IS NOT NULL AND c.access_key_secret <> '') AS has_access_key_secret,
           c.sign_name,
           c.template_code,
           c.code_expiry,
           c.tencent_sdk_app_id,
           c.config_revision,
           c.status,
           c.review_note,
           c.created_at,
           c.updated_at,
           COALESCE(NULLIF(m.business_name, ''), NULLIF(m.company_name, ''), m.id::text) AS merchant_name
    FROM public.manager_sms_configs c
    JOIN public.managers m ON m.id = c.root_manager_id
  ) r;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_sms_configs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_sms_configs() TO authenticated;

-- 平台：审核商户短信通道（绑定 config_revision 防 TOCTOU，批准前重验完整性）
CREATE OR REPLACE FUNCTION public.admin_review_sms_channel(
  p_root_manager_id uuid,
  p_status text,
  p_expected_revision uuid,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_status text;
  v_provider text;
  v_akid text;
  v_secret text;
  v_sign text;
  v_template text;
  v_expiry integer;
  v_sdk text;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  IF p_status NOT IN ('approved','rejected','pending') THEN
    RAISE EXCEPTION '不支持的状态' USING ERRCODE = 'P0002';
  END IF;

  IF p_status = 'approved' THEN
    SELECT provider, access_key_id, access_key_secret, sign_name, template_code, code_expiry, tencent_sdk_app_id
      INTO v_provider, v_akid, v_secret, v_sign, v_template, v_expiry, v_sdk
    FROM public.manager_sms_configs
    WHERE root_manager_id = p_root_manager_id
      AND config_revision = p_expected_revision;

    IF v_provider IS NULL
       OR v_provider NOT IN ('aliyun','tencent')
       OR v_akid IS NULL OR v_akid = ''
       OR v_secret IS NULL OR v_secret = ''
       OR v_sign IS NULL OR v_sign = ''
       OR v_template IS NULL OR v_template = ''
       OR COALESCE(v_expiry, 0) < 1 OR COALESCE(v_expiry, 0) > 30
       OR (v_provider = 'tencent' AND (v_sdk IS NULL OR v_sdk = '')) THEN
      RAISE EXCEPTION '该商户短信通道配置不完整，无法通过' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  UPDATE public.manager_sms_configs
     SET status = p_status,
         review_note = btrim(COALESCE(p_note, '')),
         updated_at = now()
   WHERE root_manager_id = p_root_manager_id
     AND config_revision = p_expected_revision
   RETURNING status INTO v_status;

  IF v_status IS NULL THEN
    RAISE EXCEPTION '该商户已修改短信通道，请刷新后重新审核' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object('root_manager_id', p_root_manager_id, 'status', v_status);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_review_sms_channel(uuid, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_review_sms_channel(uuid, text, uuid, text) TO authenticated;

-- 平台：集中列出全部自定义域名（供接入审核）
CREATE OR REPLACE FUNCTION public.admin_list_all_domains()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT d.id,
           d.root_manager_id,
           d.hostname,
           d.status,
           d.verified_at,
           d.created_at,
           COALESCE(NULLIF(m.business_name, ''), NULLIF(m.company_name, ''), m.id::text) AS merchant_name
    FROM public.manager_domains d
    JOIN public.managers m ON m.id = d.root_manager_id
  ) r;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_all_domains() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_all_domains() TO authenticated;