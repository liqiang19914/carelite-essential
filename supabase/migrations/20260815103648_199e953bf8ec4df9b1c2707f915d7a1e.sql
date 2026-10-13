-- 平台微信支付收款配置：安全加固
-- 1) 保存前显式校验，绝不让 CHECK 失败行把密钥明文带进错误响应
-- 2) 启用状态机：未接管回退旧密钥、显式关闭才禁止两种来源
-- 3) 凭证变更退出启用态，杜绝未自检凭证被用于真实收款
-- 4) config_revision 并发守卫，杜绝迟到自检结果误标新配置
-- 5) 保存与启停写操作日志（不含任何密钥值）

ALTER TABLE public.platform_wechat_pay_config
  ADD COLUMN IF NOT EXISTS config_revision bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS explicitly_disabled boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.platform_wechat_pay_config.config_revision IS
  '凭证/配置每次变化即递增；自检落库用它守卫，防止「检的是旧凭证、激活的是并发保存后的新凭证」。';
COMMENT ON COLUMN public.platform_wechat_pay_config.explicitly_disabled IS
  '管理员显式关闭收款时置 true；加载器据此区分「尚未接管（回退旧密钥）」与「显式关闭（禁止两种来源）」。';


-- ─── 保存：显式校验 + 凭证变更退出启用态 + 操作日志 ────────────────────────
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
  v_actor   text;
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

  -- 显式校验：写库前抛不含数据的业务异常，绝不触发 CHECK 失败行回显
  IF v_mch IS NOT NULL AND v_mch !~ '^[0-9]+$' THEN
    RAISE EXCEPTION '商户号只能是数字' USING ERRCODE = '22023';
  END IF;
  IF v_key IS NOT NULL AND (char_length(v_key) <> 32 OR octet_length(v_key) <> 32) THEN
    RAISE EXCEPTION 'APIv3 密钥必须是 32 位英文数字，请从微信支付商户平台重新复制' USING ERRCODE = '22023';
  END IF;
  IF v_pubid IS NOT NULL AND v_pubid NOT LIKE 'PUB\_KEY\_ID\_%' THEN
    RAISE EXCEPTION '微信支付公钥 ID 必须以 PUB_KEY_ID_ 开头' USING ERRCODE = '22023';
  END IF;
  IF (v_pubid IS NULL) <> (v_pubpem IS NULL) THEN
    RAISE EXCEPTION '微信支付公钥的「公钥ID」和「公钥内容」必须同时填写或同时清空' USING ERRCODE = '22023';
  END IF;
  IF v_pem IS NOT NULL AND length(btrim(v_pem)) = 0 THEN
    RAISE EXCEPTION '商户私钥内容不能为空' USING ERRCODE = '22023';
  END IF;
  IF v_serial IS NOT NULL AND length(btrim(v_serial)) = 0 THEN
    RAISE EXCEPTION '证书序列号不能为空' USING ERRCODE = '22023';
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

  -- 凭证一变：退出启用态（重新自检并开启前绝不用新凭证收款），并递增修订号
  UPDATE public.platform_wechat_pay_config
  SET mch_id                    = v_mch,
      api_v3_key                = v_key,
      merchant_private_key_pem  = v_pem,
      merchant_cert_serial_no   = v_serial,
      wechatpay_public_key_id   = v_pubid,
      wechatpay_public_key_pem  = v_pubpem,
      config_revision           = v_cur.config_revision + 1,
      is_enabled                = false,
      explicitly_disabled       = false,
      verification_status       = v_status,
      verification_summary      = '',
      verification_warnings     = '{}',
      last_checked_at           = NULL,
      updated_by                = v_caller,
      updated_at                = now()
  WHERE singleton_key = true;

  SELECT nickname INTO v_actor FROM public.profiles WHERE id = v_caller;
  INSERT INTO public.operation_logs
    (user_id, action, detail, module, metadata, actor_name_snapshot)
  VALUES (
    v_caller,
    '更新平台微信支付收款配置',
    '配置状态：' || v_status,
    '支付配置',
    jsonb_build_object('changed', true, 'verification_status', v_status),
    coalesce(v_actor, '')
  );

  RETURN jsonb_build_object(
    'success', true, 'changed', true,
    'verification_status', v_status
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_save_platform_wechat_pay_config(jsonb, jsonb, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_save_platform_wechat_pay_config(jsonb, jsonb, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_save_platform_wechat_pay_config(jsonb, jsonb, text[]) TO authenticated;


-- ─── 启停开关：开启须自检通过；关闭置显式禁用标记；写操作日志 ───────────────
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
  v_actor text;
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
  SET is_enabled = p_enabled,
      explicitly_disabled = NOT p_enabled,
      updated_by = v_caller,
      updated_at = now()
  WHERE singleton_key = true;

  SELECT nickname INTO v_actor FROM public.profiles WHERE id = v_caller;
  INSERT INTO public.operation_logs
    (user_id, action, detail, module, metadata, actor_name_snapshot)
  VALUES (
    v_caller,
    CASE WHEN p_enabled THEN '开启平台收款' ELSE '关闭平台收款' END,
    '商户号 ' || coalesce(v_a.mch_id, '未填'),
    '支付配置',
    jsonb_build_object('enabled', p_enabled),
    coalesce(v_actor, '')
  );

  RETURN jsonb_build_object('success', true, 'changed', true, 'is_enabled', p_enabled);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_platform_wechat_pay_config_enabled(boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_platform_wechat_pay_config_enabled(boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_set_platform_wechat_pay_config_enabled(boolean) TO authenticated;


-- ─── 自检结果落库：加修订号并发守卫（仅 service_role） ─────────────────────
DROP FUNCTION IF EXISTS public.record_platform_wechat_pay_self_check(boolean, text, text[]);

CREATE OR REPLACE FUNCTION public.record_platform_wechat_pay_self_check(
  p_config_revision bigint,
  p_passed          boolean,
  p_summary         text,
  p_warnings        text[] DEFAULT '{}'::text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cur public.platform_wechat_pay_config;
BEGIN
  SELECT * INTO v_cur FROM public.platform_wechat_pay_config
  WHERE singleton_key = true FOR UPDATE;

  IF v_cur.id IS NULL THEN
    RAISE EXCEPTION '平台收款配置不存在' USING ERRCODE = '22023';
  END IF;

  IF v_cur.config_revision <> p_config_revision THEN
    RAISE EXCEPTION '配置在自检过程中已被修改，请重新自检' USING ERRCODE = '40001';
  END IF;

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

REVOKE ALL ON FUNCTION public.record_platform_wechat_pay_self_check(bigint, boolean, text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_platform_wechat_pay_self_check(bigint, boolean, text, text[]) FROM anon;
REVOKE ALL ON FUNCTION public.record_platform_wechat_pay_self_check(bigint, boolean, text, text[]) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.record_platform_wechat_pay_self_check(bigint, boolean, text, text[]) TO service_role;