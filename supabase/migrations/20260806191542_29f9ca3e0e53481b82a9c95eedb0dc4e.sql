-- ============================================================================
-- 商户独立微信收款：配置读写 RPC（只写不读语义）+ 自检落库 + 收款方查询
--
-- 「只写不读」核心规则（血的教训：微信登录凭证曾被整表单提交的空串清空过一次）：
--   · 字段缺省 或 传空白  → 保持库里原值不动
--   · 只有把字段名放进 p_clear_secrets 才会真正清空
-- 因此前端就算沿用「遍历所有字段一律提交」的写法，也绝不会抹掉已存的私钥。
-- ============================================================================

-- ─── 内部：应用配置变更，必要时递增 revision 并作废已激活凭证版本 ────────────
CREATE OR REPLACE FUNCTION public._apply_manager_wechat_pay_config(
  p_manager_id    uuid,
  p_actor_id      uuid,
  p_config        jsonb,
  p_secrets       jsonb,
  p_clear_secrets text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_in      jsonb := coalesce(p_config, '{}'::jsonb) || coalesce(p_secrets, '{}'::jsonb);
  v_clear   text[] := coalesce(p_clear_secrets, '{}'::text[]);
  v_cur     public.manager_wechat_pay_accounts;
  v_mch     text;
  v_key     text;
  v_pem     text;
  v_serial  text;
  v_pubid   text;
  v_pubpem  text;
  v_changed boolean;
  v_status  text;
BEGIN
  INSERT INTO public.manager_wechat_pay_accounts (manager_id, created_by, updated_by)
  VALUES (p_manager_id, p_actor_id, p_actor_id)
  ON CONFLICT (manager_id) DO NOTHING;

  SELECT * INTO v_cur
  FROM public.manager_wechat_pay_accounts
  WHERE manager_id = p_manager_id
  FOR UPDATE;

  -- 商户号：token 型，去掉所有空白（用户常从网页复制带空格）
  v_mch := CASE
    WHEN 'mch_id' = ANY(v_clear) THEN NULL
    WHEN btrim(coalesce(v_in->>'mch_id', '')) <> ''
      THEN regexp_replace(v_in->>'mch_id', '\s', '', 'g')
    ELSE v_cur.mch_id
  END;

  v_key := CASE
    WHEN 'api_v3_key' = ANY(v_clear) THEN NULL
    WHEN btrim(coalesce(v_in->>'api_v3_key', '')) <> '' THEN btrim(v_in->>'api_v3_key')
    ELSE v_cur.api_v3_key
  END;

  v_pem := CASE
    WHEN 'merchant_private_key_pem' = ANY(v_clear) THEN NULL
    WHEN btrim(coalesce(v_in->>'merchant_private_key_pem', '')) <> ''
      THEN btrim(v_in->>'merchant_private_key_pem')
    ELSE v_cur.merchant_private_key_pem
  END;

  v_serial := CASE
    WHEN 'merchant_cert_serial_no' = ANY(v_clear) THEN NULL
    WHEN btrim(coalesce(v_in->>'merchant_cert_serial_no', '')) <> ''
      THEN upper(regexp_replace(v_in->>'merchant_cert_serial_no', '\s', '', 'g'))
    ELSE v_cur.merchant_cert_serial_no
  END;

  v_pubid := CASE
    WHEN 'wechatpay_public_key_id' = ANY(v_clear) THEN NULL
    WHEN btrim(coalesce(v_in->>'wechatpay_public_key_id', '')) <> ''
      THEN regexp_replace(v_in->>'wechatpay_public_key_id', '\s', '', 'g')
    ELSE v_cur.wechatpay_public_key_id
  END;

  v_pubpem := CASE
    WHEN 'wechatpay_public_key_pem' = ANY(v_clear) THEN NULL
    WHEN btrim(coalesce(v_in->>'wechatpay_public_key_pem', '')) <> ''
      THEN btrim(v_in->>'wechatpay_public_key_pem')
    ELSE v_cur.wechatpay_public_key_pem
  END;

  -- 微信支付公钥 ID 与 PEM 必须成对；只填一半直接拦下，别等回调验签时才炸
  IF (v_pubid IS NULL) <> (v_pubpem IS NULL) THEN
    RAISE EXCEPTION '微信支付公钥的「公钥ID」和「公钥内容」必须同时填写或同时清空'
      USING ERRCODE = '22023';
  END IF;

  v_changed :=
    v_mch     IS DISTINCT FROM v_cur.mch_id
    OR v_key    IS DISTINCT FROM v_cur.api_v3_key
    OR v_pem    IS DISTINCT FROM v_cur.merchant_private_key_pem
    OR v_serial IS DISTINCT FROM v_cur.merchant_cert_serial_no
    OR v_pubid  IS DISTINCT FROM v_cur.wechatpay_public_key_id
    OR v_pubpem IS DISTINCT FROM v_cur.wechatpay_public_key_pem;

  v_status := CASE
    WHEN v_mch IS NOT NULL AND v_key IS NOT NULL
      AND v_pem IS NOT NULL AND v_serial IS NOT NULL THEN 'unchecked'
    WHEN v_mch IS NULL AND v_key IS NULL
      AND v_pem IS NULL AND v_serial IS NULL THEN 'unconfigured'
    ELSE 'incomplete'
  END;

  IF NOT v_changed THEN
    RETURN jsonb_build_object(
      'success', true, 'changed', false,
      'config_revision', v_cur.config_revision,
      'verification_status', v_cur.verification_status
    );
  END IF;

  -- 凭证一变，已激活版本立即作废：宁可让新订单明确报「需重新自检」，
  -- 也不能拿一半新一半旧的凭证去发起真实收款
  UPDATE public.manager_wechat_pay_accounts
  SET mch_id                       = v_mch,
      api_v3_key                   = v_key,
      merchant_private_key_pem     = v_pem,
      merchant_cert_serial_no      = v_serial,
      wechatpay_public_key_id      = v_pubid,
      wechatpay_public_key_pem     = v_pubpem,
      config_revision              = v_cur.config_revision + 1,
      active_credential_version_id = NULL,
      verification_status          = v_status,
      verification_summary         = '',
      verification_warnings        = '{}',
      last_checked_at              = NULL,
      updated_by                   = p_actor_id,
      updated_at                   = now()
  WHERE manager_id = p_manager_id;

  RETURN jsonb_build_object(
    'success', true, 'changed', true,
    'config_revision', v_cur.config_revision + 1,
    'verification_status', v_status
  );
END;
$$;

REVOKE ALL ON FUNCTION public._apply_manager_wechat_pay_config(uuid, uuid, jsonb, jsonb, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._apply_manager_wechat_pay_config(uuid, uuid, jsonb, jsonb, text[]) FROM anon;
REVOKE ALL ON FUNCTION public._apply_manager_wechat_pay_config(uuid, uuid, jsonb, jsonb, text[]) FROM authenticated;


-- ─── 读取：永不返回任何密钥本体，只返回 has_* 与状态 ────────────────────────
CREATE OR REPLACE FUNCTION public.get_manager_wechat_pay_account(
  p_manager_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller  uuid := auth.uid();
  v_is_admin boolean;
  v_target  uuid;
  v_root    uuid;
  v_is_root boolean;
  v_a       public.manager_wechat_pay_accounts;
  v_oem_enabled boolean;
  v_app_id  text;
  v_biz     text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  v_is_admin := public.is_admin(v_caller);

  IF v_is_admin THEN
    IF p_manager_id IS NULL THEN
      RAISE EXCEPTION '缺少商户参数' USING ERRCODE = '22023';
    END IF;
    v_target := p_manager_id;
  ELSE
    -- 员工不得读取企业收款配置状态，连「有没有配」都不告诉
    SELECT parent_manager_id IS NULL INTO v_is_root FROM public.profiles WHERE id = v_caller;
    IF v_is_root IS NULL THEN
      RAISE EXCEPTION '当前账号无权查看收款配置' USING ERRCODE = '42501';
    END IF;
    IF NOT v_is_root THEN
      RAISE EXCEPTION '仅企业负责人可查看收款配置' USING ERRCODE = '42501';
    END IF;
    v_target := v_caller;
  END IF;

  SELECT COALESCE(parent_manager_id, id) INTO v_root FROM public.profiles WHERE id = v_target;
  IF v_root IS NULL THEN
    RAISE EXCEPTION '商户不存在' USING ERRCODE = '22023';
  END IF;

  SELECT business_name INTO v_biz FROM public.managers WHERE id = v_root;
  IF v_biz IS NULL THEN
    RAISE EXCEPTION '商户不存在' USING ERRCODE = '22023';
  END IF;

  SELECT is_enabled, app_id INTO v_oem_enabled, v_app_id
  FROM public.manager_miniprograms WHERE manager_id = v_root;

  SELECT * INTO v_a FROM public.manager_wechat_pay_accounts WHERE manager_id = v_root;

  RETURN jsonb_build_object(
    'manager_id',              v_root,
    'business_name',           coalesce(v_biz, ''),
    'row_exists',              v_a.id IS NOT NULL,
    'is_enabled',              coalesce(v_a.is_enabled, false),
    'oem_enabled',             coalesce(v_oem_enabled, false),
    'oem_app_id',              coalesce(v_app_id, ''),
    'mch_id',                  coalesce(v_a.mch_id, ''),
    'merchant_cert_serial_no', coalesce(v_a.merchant_cert_serial_no, ''),
    'wechatpay_public_key_id', coalesce(v_a.wechatpay_public_key_id, ''),
    'has_api_v3_key',          v_a.api_v3_key IS NOT NULL,
    'has_merchant_private_key', v_a.merchant_private_key_pem IS NOT NULL,
    'has_wechatpay_public_key', v_a.wechatpay_public_key_pem IS NOT NULL,
    'verification_status',     coalesce(v_a.verification_status, 'unconfigured'),
    'verification_summary',    coalesce(v_a.verification_summary, ''),
    'verification_warnings',   to_jsonb(coalesce(v_a.verification_warnings, '{}'::text[])),
    'last_checked_at',         v_a.last_checked_at,
    'config_revision',         coalesce(v_a.config_revision, 0),
    'has_active_version',      v_a.active_credential_version_id IS NOT NULL,
    'can_edit',                v_is_admin OR coalesce(v_oem_enabled, false),
    'can_toggle',              v_is_admin,
    'viewer_is_admin',         v_is_admin
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_manager_wechat_pay_account(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_manager_wechat_pay_account(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_manager_wechat_pay_account(uuid) TO authenticated;


-- ─── 平台后台保存 ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_save_manager_wechat_pay_account(
  p_manager_id    uuid,
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
  v_is_root boolean;
BEGIN
  IF NOT public.is_admin(v_caller) THEN
    RAISE EXCEPTION '仅平台管理员可操作' USING ERRCODE = '42501';
  END IF;

  SELECT parent_manager_id IS NULL INTO v_is_root FROM public.profiles WHERE id = p_manager_id;
  IF v_is_root IS NULL THEN
    RAISE EXCEPTION '商户不存在' USING ERRCODE = '22023';
  END IF;
  IF NOT v_is_root THEN
    RAISE EXCEPTION '收款账户只能配置在企业负责人名下，不能配置到员工账号' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.managers WHERE id = p_manager_id) THEN
    RAISE EXCEPTION '商户不存在' USING ERRCODE = '22023';
  END IF;

  RETURN public._apply_manager_wechat_pay_config(
    p_manager_id, v_caller, p_config, p_secrets, p_clear_secrets
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_save_manager_wechat_pay_account(uuid, jsonb, jsonb, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_save_manager_wechat_pay_account(uuid, jsonb, jsonb, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_save_manager_wechat_pay_account(uuid, jsonb, jsonb, text[]) TO authenticated;


-- ─── 商户自助保存 ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manager_save_my_wechat_pay_account(
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
  v_is_root boolean;
  v_cert text;
  v_oem boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT parent_manager_id IS NULL INTO v_is_root FROM public.profiles WHERE id = v_caller;
  IF v_is_root IS NULL OR NOT v_is_root THEN
    RAISE EXCEPTION '仅企业负责人可配置收款账户' USING ERRCODE = '42501';
  END IF;

  SELECT certification_status INTO v_cert FROM public.managers WHERE id = v_caller;
  IF v_cert IS NULL THEN
    RAISE EXCEPTION '当前账号不是管理师' USING ERRCODE = '42501';
  END IF;
  IF v_cert <> 'approved' THEN
    RAISE EXCEPTION '账号未审核通过，无法配置收款账户' USING ERRCODE = '42501';
  END IF;

  SELECT is_enabled INTO v_oem FROM public.manager_miniprograms WHERE manager_id = v_caller;
  IF v_oem IS NULL OR NOT v_oem THEN
    RAISE EXCEPTION '尚未开通独立小程序，请联系平台开通后再配置收款' USING ERRCODE = '42501';
  END IF;

  RETURN public._apply_manager_wechat_pay_config(
    v_caller, v_caller, p_config, p_secrets, p_clear_secrets
  );
END;
$$;

REVOKE ALL ON FUNCTION public.manager_save_my_wechat_pay_account(jsonb, jsonb, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.manager_save_my_wechat_pay_account(jsonb, jsonb, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.manager_save_my_wechat_pay_account(jsonb, jsonb, text[]) TO authenticated;