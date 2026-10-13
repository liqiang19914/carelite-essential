-- 平台微信支付收款配置（单例，收平台自营商品 / 会员套餐的钱）
-- 密钥只写不读：读取只经 RPC 返回 has_* 布尔，永不回显明文。

CREATE TABLE IF NOT EXISTS public.platform_wechat_pay_config (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  singleton_key boolean NOT NULL DEFAULT true UNIQUE CHECK (singleton_key),

  mch_id text,
  api_v3_key text,
  merchant_private_key_pem text,
  merchant_cert_serial_no text,
  wechatpay_public_key_id text,
  wechatpay_public_key_pem text,

  is_enabled boolean NOT NULL DEFAULT false,

  verification_status text NOT NULL DEFAULT 'unconfigured'
    CHECK (verification_status IN ('unconfigured','incomplete','unchecked','passed','failed')),
  verification_summary text NOT NULL DEFAULT '',
  verification_warnings text[] NOT NULL DEFAULT '{}',
  last_checked_at timestamptz,

  updated_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT pwpc_mch_id_digits CHECK (mch_id IS NULL OR mch_id ~ '^[0-9]+$'),
  CONSTRAINT pwpc_api_v3_key_len CHECK (
    api_v3_key IS NULL
    OR (char_length(api_v3_key) = 32 AND octet_length(api_v3_key) = 32)
  ),
  CONSTRAINT pwpc_private_key_nonblank CHECK (
    merchant_private_key_pem IS NULL OR length(btrim(merchant_private_key_pem)) > 0
  ),
  CONSTRAINT pwpc_cert_serial_nonblank CHECK (
    merchant_cert_serial_no IS NULL OR length(btrim(merchant_cert_serial_no)) > 0
  ),
  CONSTRAINT pwpc_pubkey_id_prefix CHECK (
    wechatpay_public_key_id IS NULL OR wechatpay_public_key_id LIKE 'PUB\_KEY\_ID\_%'
  ),
  CONSTRAINT pwpc_pubkey_paired CHECK (
    (wechatpay_public_key_id IS NULL AND wechatpay_public_key_pem IS NULL)
    OR (wechatpay_public_key_id LIKE 'PUB\_KEY\_ID\_%'
        AND length(btrim(wechatpay_public_key_pem)) > 0)
  )
);

ALTER TABLE public.platform_wechat_pay_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.platform_wechat_pay_config FROM PUBLIC;
REVOKE ALL ON public.platform_wechat_pay_config FROM anon;
REVOKE ALL ON public.platform_wechat_pay_config FROM authenticated;


-- ─── 读取：仅平台管理员；永不返回密钥本体 ────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_platform_wechat_pay_config()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_a public.platform_wechat_pay_config;
BEGIN
  IF v_caller IS NULL OR NOT public.is_admin(v_caller) THEN
    RAISE EXCEPTION '仅平台管理员可操作' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_a FROM public.platform_wechat_pay_config LIMIT 1;

  RETURN jsonb_build_object(
    'row_exists',               v_a.id IS NOT NULL,
    'is_enabled',               coalesce(v_a.is_enabled, false),
    'mch_id',                   coalesce(v_a.mch_id, ''),
    'merchant_cert_serial_no',  coalesce(v_a.merchant_cert_serial_no, ''),
    'wechatpay_public_key_id',  coalesce(v_a.wechatpay_public_key_id, ''),
    'has_api_v3_key',           v_a.api_v3_key IS NOT NULL,
    'has_merchant_private_key', v_a.merchant_private_key_pem IS NOT NULL,
    'has_wechatpay_public_key', v_a.wechatpay_public_key_pem IS NOT NULL,
    'verification_status',      coalesce(v_a.verification_status, 'unconfigured'),
    'verification_summary',     coalesce(v_a.verification_summary, ''),
    'verification_warnings',    to_jsonb(coalesce(v_a.verification_warnings, '{}'::text[])),
    'last_checked_at',          v_a.last_checked_at,
    'can_edit',                 true,
    'can_toggle',               true
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_get_platform_wechat_pay_config() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_get_platform_wechat_pay_config() FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_get_platform_wechat_pay_config() TO authenticated;


-- ─── 保存：只写不读语义（缺省/空白不覆盖，只有进 p_clear_secrets 才清空）───
CREATE OR REPLACE FUNCTION public.admin_save_platform_wechat_pay_config(
  p_config        jsonb DEFAULT '{}'::jsonb,
  p_secrets       jsonb DEFAULT '{}'::jsonb,
  p_clear_secrets text[] DEFAULT '{}'::text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_in     jsonb := coalesce(p_config, '{}'::jsonb) || coalesce(p_secrets, '{}'::jsonb);
  v_clear  text[] := coalesce(p_clear_secrets, '{}'::text[]);
  v_cur    public.platform_wechat_pay_config;
  v_mch    text;
  v_key    text;
  v_pem    text;
  v_serial text;
  v_pubid  text;
  v_pubpem text;
  v_changed boolean;
  v_status  text;
BEGIN
  IF NOT public.is_admin(v_caller) THEN
    RAISE EXCEPTION '仅平台管理员可操作' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.platform_wechat_pay_config (singleton_key, updated_by)
  VALUES (true, v_caller)
  ON CONFLICT (singleton_key) DO NOTHING;

  SELECT * INTO v_cur FROM public.platform_wechat_pay_config
  WHERE singleton_key = true FOR UPDATE;

  v_mch := CASE
    WHEN 'mch_id' = ANY(v_clear) THEN NULL
    WHEN btrim(coalesce(v_in->>'mch_id', '')) <> '' THEN regexp_replace(v_in->>'mch_id', '\s', '', 'g')
    ELSE v_cur.mch_id END;

  v_key := CASE
    WHEN 'api_v3_key' = ANY(v_clear) THEN NULL
    WHEN btrim(coalesce(v_in->>'api_v3_key', '')) <> '' THEN btrim(v_in->>'api_v3_key')
    ELSE v_cur.api_v3_key END;

  v_pem := CASE
    WHEN 'merchant_private_key_pem' = ANY(v_clear) THEN NULL
    WHEN btrim(coalesce(v_in->>'merchant_private_key_pem', '')) <> '' THEN btrim(v_in->>'merchant_private_key_pem')
    ELSE v_cur.merchant_private_key_pem END;

  v_serial := CASE
    WHEN 'merchant_cert_serial_no' = ANY(v_clear) THEN NULL
    WHEN btrim(coalesce(v_in->>'merchant_cert_serial_no', '')) <> '' THEN upper(regexp_replace(v_in->>'merchant_cert_serial_no', '\s', '', 'g'))
    ELSE v_cur.merchant_cert_serial_no END;

  v_pubid := CASE
    WHEN 'wechatpay_public_key_id' = ANY(v_clear) THEN NULL
    WHEN btrim(coalesce(v_in->>'wechatpay_public_key_id', '')) <> '' THEN regexp_replace(v_in->>'wechatpay_public_key_id', '\s', '', 'g')
    ELSE v_cur.wechatpay_public_key_id END;

  v_pubpem := CASE
    WHEN 'wechatpay_public_key_pem' = ANY(v_clear) THEN NULL
    WHEN btrim(coalesce(v_in->>'wechatpay_public_key_pem', '')) <> '' THEN btrim(v_in->>'wechatpay_public_key_pem')
    ELSE v_cur.wechatpay_public_key_pem END;

  IF (v_pubid IS NULL) <> (v_pubpem IS NULL) THEN
    RAISE EXCEPTION '微信支付公钥的「公钥ID」和「公钥内容」必须同时填写或同时清空' USING ERRCODE = '22023';
  END IF;

  v_changed :=
    v_mch     IS DISTINCT FROM v_cur.mch_id
    OR v_key   IS DISTINCT FROM v_cur.api_v3_key
    OR v_pem   IS DISTINCT FROM v_cur.merchant_private_key_pem
    OR v_serial IS DISTINCT FROM v_cur.merchant_cert_serial_no
    OR v_pubid IS DISTINCT FROM v_cur.wechatpay_public_key_id
    OR v_pubpem IS DISTINCT FROM v_cur.wechatpay_public_key_pem;

  v_status := CASE
    WHEN v_mch IS NOT NULL AND v_key IS NOT NULL AND v_pem IS NOT NULL AND v_serial IS NOT NULL THEN 'unchecked'
    WHEN v_mch IS NULL AND v_key IS NULL AND v_pem IS NULL AND v_serial IS NULL THEN 'unconfigured'
    ELSE 'incomplete'
  END;

  IF NOT v_changed THEN
    RETURN jsonb_build_object(
      'success', true, 'changed', false,
      'verification_status', v_cur.verification_status
    );
  END IF;

  UPDATE public.platform_wechat_pay_config
  SET mch_id                    = v_mch,
      api_v3_key                = v_key,
      merchant_private_key_pem  = v_pem,
      merchant_cert_serial_no   = v_serial,
      wechatpay_public_key_id   = v_pubid,
      wechatpay_public_key_pem  = v_pubpem,
      verification_status       = v_status,
      verification_summary      = '',
      verification_warnings     = '{}',
      last_checked_at           = NULL,
      updated_by                = v_caller,
      updated_at                = now()
  WHERE singleton_key = true;

  RETURN jsonb_build_object(
    'success', true, 'changed', true,
    'verification_status', v_status
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_save_platform_wechat_pay_config(jsonb, jsonb, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_save_platform_wechat_pay_config(jsonb, jsonb, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_save_platform_wechat_pay_config(jsonb, jsonb, text[]) TO authenticated;


-- ─── 启停开关：开启前必须自检通过 ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_set_platform_wechat_pay_config_enabled(
  p_enabled boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_a public.platform_wechat_pay_config;
BEGIN
  IF NOT public.is_admin(v_caller) THEN
    RAISE EXCEPTION '仅平台管理员可操作' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_a FROM public.platform_wechat_pay_config
  WHERE singleton_key = true FOR UPDATE;

  IF v_a.id IS NULL THEN
    RAISE EXCEPTION '还没有平台收款配置，请先填写商户号与密钥' USING ERRCODE = '22023';
  END IF;

  IF p_enabled AND v_a.verification_status <> 'passed' THEN
    RAISE EXCEPTION '平台收款配置尚未通过连通性自检，无法开启' USING ERRCODE = '22023';
  END IF;

  UPDATE public.platform_wechat_pay_config
  SET is_enabled = p_enabled, updated_by = v_caller, updated_at = now()
  WHERE singleton_key = true;

  RETURN jsonb_build_object('success', true, 'changed', true, 'is_enabled', p_enabled);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_platform_wechat_pay_config_enabled(boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_platform_wechat_pay_config_enabled(boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_set_platform_wechat_pay_config_enabled(boolean) TO authenticated;


-- ─── 自检结果落库：仅 service_role（由 Edge Function 真实握微信接口后回写）──
CREATE OR REPLACE FUNCTION public.record_platform_wechat_pay_self_check(
  p_passed   boolean,
  p_summary  text,
  p_warnings text[] DEFAULT '{}'::text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.platform_wechat_pay_config
  SET verification_status   = CASE WHEN p_passed THEN 'passed' ELSE 'failed' END,
      verification_summary  = coalesce(p_summary, ''),
      verification_warnings = coalesce(p_warnings, '{}'),
      last_checked_at       = now(),
      updated_at            = now()
  WHERE singleton_key = true;

  RETURN jsonb_build_object('success', true, 'passed', p_passed);
END;
$$;

REVOKE ALL ON FUNCTION public.record_platform_wechat_pay_self_check(boolean, text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_platform_wechat_pay_self_check(boolean, text, text[]) FROM anon;
REVOKE ALL ON FUNCTION public.record_platform_wechat_pay_self_check(boolean, text, text[]) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.record_platform_wechat_pay_self_check(boolean, text, text[]) TO service_role;