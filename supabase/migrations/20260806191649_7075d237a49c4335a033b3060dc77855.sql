-- ============================================================================
-- 商户独立微信收款：平台开关 + 自检落库冻结凭证版本 + 订单收款方查询
-- ============================================================================

-- ─── 平台开关：只有自检通过、且已冻结出可用凭证版本才允许开启 ────────────────
CREATE OR REPLACE FUNCTION public.admin_set_manager_wechat_pay_account_enabled(
  p_manager_id uuid,
  p_enabled    boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_a public.manager_wechat_pay_accounts;
  v_actor text;
  v_biz text;
BEGIN
  IF NOT public.is_admin(v_caller) THEN
    RAISE EXCEPTION '仅平台管理员可操作' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_a FROM public.manager_wechat_pay_accounts
  WHERE manager_id = p_manager_id FOR UPDATE;

  IF v_a.id IS NULL THEN
    RAISE EXCEPTION '该商户还没有收款账户配置，请先填写商户号与密钥' USING ERRCODE = '22023';
  END IF;

  IF p_enabled AND v_a.active_credential_version_id IS NULL THEN
    RAISE EXCEPTION '收款配置尚未通过连通性自检，无法开启商户独立收款' USING ERRCODE = '22023';
  END IF;

  IF v_a.is_enabled = p_enabled THEN
    RETURN jsonb_build_object('success', true, 'changed', false, 'is_enabled', p_enabled);
  END IF;

  UPDATE public.manager_wechat_pay_accounts
  SET is_enabled = p_enabled, updated_by = v_caller, updated_at = now()
  WHERE manager_id = p_manager_id;

  SELECT nickname INTO v_actor FROM public.profiles WHERE id = v_caller;
  SELECT business_name INTO v_biz FROM public.managers WHERE id = p_manager_id;

  INSERT INTO public.operation_logs
    (user_id, action, detail, module, metadata, enterprise_root_id, actor_name_snapshot)
  VALUES (
    v_caller,
    CASE WHEN p_enabled THEN '开启商户独立收款' ELSE '关闭商户独立收款' END,
    coalesce(v_biz, '') || '（商户号 ' || coalesce(v_a.mch_id, '未填') || '）',
    '支付配置',
    jsonb_build_object('manager_id', p_manager_id, 'enabled', p_enabled),
    p_manager_id,
    coalesce(v_actor, '')
  );

  RETURN jsonb_build_object('success', true, 'changed', true, 'is_enabled', p_enabled);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_manager_wechat_pay_account_enabled(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_set_manager_wechat_pay_account_enabled(uuid, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_set_manager_wechat_pay_account_enabled(uuid, boolean) TO authenticated;


-- ─── 自检结果落库：通过则冻结出不可变凭证版本 ───────────────────────────────
-- 仅 service_role 可调用（由 Edge Function 在真实握过微信接口之后回写）。
-- p_config_revision 是并发守卫：自检期间配置被改过就拒绝激活，
-- 否则会出现「自检的是旧密钥、激活的是新密钥」这种最难查的错配。
CREATE OR REPLACE FUNCTION public.record_manager_wechat_pay_self_check(
  p_account_id      uuid,
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
  v_a public.manager_wechat_pay_accounts;
  v_version_id uuid;
  v_token text;
BEGIN
  SELECT * INTO v_a FROM public.manager_wechat_pay_accounts
  WHERE id = p_account_id FOR UPDATE;

  IF v_a.id IS NULL THEN
    RAISE EXCEPTION '收款账户不存在' USING ERRCODE = '22023';
  END IF;

  IF v_a.config_revision <> p_config_revision THEN
    RAISE EXCEPTION '配置在自检过程中已被修改，请重新自检' USING ERRCODE = '40001';
  END IF;

  IF NOT p_passed THEN
    UPDATE public.manager_wechat_pay_accounts
    SET verification_status   = 'failed',
        verification_summary  = coalesce(p_summary, ''),
        verification_warnings = coalesce(p_warnings, '{}'),
        last_checked_at       = now(),
        updated_at            = now()
    WHERE id = p_account_id;

    RETURN jsonb_build_object('success', true, 'passed', false);
  END IF;

  IF v_a.mch_id IS NULL OR v_a.api_v3_key IS NULL
     OR v_a.merchant_private_key_pem IS NULL OR v_a.merchant_cert_serial_no IS NULL THEN
    RAISE EXCEPTION '收款配置不完整，无法激活' USING ERRCODE = '22023';
  END IF;

  -- 同一 revision 重复自检复用同一版本（含同一 notify_token），保持幂等
  INSERT INTO public.manager_wechat_pay_credential_versions (
    pay_account_id, config_revision, mch_id, api_v3_key,
    merchant_private_key_pem, merchant_cert_serial_no,
    wechatpay_public_key_id, wechatpay_public_key_pem,
    verification_warnings, created_by
  )
  VALUES (
    v_a.id, v_a.config_revision, v_a.mch_id, v_a.api_v3_key,
    v_a.merchant_private_key_pem, v_a.merchant_cert_serial_no,
    v_a.wechatpay_public_key_id, v_a.wechatpay_public_key_pem,
    coalesce(p_warnings, '{}'), v_a.updated_by
  )
  ON CONFLICT (pay_account_id, config_revision) DO NOTHING;

  SELECT id, notify_token INTO v_version_id, v_token
  FROM public.manager_wechat_pay_credential_versions
  WHERE pay_account_id = v_a.id AND config_revision = v_a.config_revision;

  UPDATE public.manager_wechat_pay_accounts
  SET active_credential_version_id = v_version_id,
      verification_status          = 'passed',
      verification_summary         = coalesce(p_summary, ''),
      verification_warnings        = coalesce(p_warnings, '{}'),
      last_checked_at              = now(),
      updated_at                   = now()
  WHERE id = p_account_id;

  RETURN jsonb_build_object(
    'success', true, 'passed', true,
    'credential_version_id', v_version_id,
    'notify_token', v_token
  );
END;
$$;

REVOKE ALL ON FUNCTION public.record_manager_wechat_pay_self_check(uuid, bigint, boolean, text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_manager_wechat_pay_self_check(uuid, bigint, boolean, text, text[]) FROM anon;
REVOKE ALL ON FUNCTION public.record_manager_wechat_pay_self_check(uuid, bigint, boolean, text, text[]) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.record_manager_wechat_pay_self_check(uuid, bigint, boolean, text, text[]) TO service_role;


-- ─── 订单收款方查询（平台客服处理纠纷用；绝不返回任何密钥） ──────────────────
CREATE OR REPLACE FUNCTION public.admin_get_order_payment_collection(
  p_out_trade_no text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_p record;
  v_biz text;
BEGIN
  IF NOT public.is_admin(v_caller) THEN
    RAISE EXCEPTION '仅平台管理员可操作' USING ERRCODE = '42501';
  END IF;

  SELECT po.payee_type, po.payee_manager_id, po.mch_id, po.status,
         po.wechat_transaction_id, po.notified_at, po.appid, po.created_at
  INTO v_p
  FROM public.wechat_miniapp_pay_orders po
  WHERE po.out_trade_no = p_out_trade_no;

  IF v_p IS NULL THEN
    RETURN jsonb_build_object('exists', false);
  END IF;

  IF v_p.payee_manager_id IS NOT NULL THEN
    SELECT business_name INTO v_biz FROM public.managers WHERE id = v_p.payee_manager_id;
  END IF;

  RETURN jsonb_build_object(
    'exists',                true,
    'payee_type',            v_p.payee_type,
    'payee_manager_id',      v_p.payee_manager_id,
    'payee_business_name',   coalesce(v_biz, ''),
    'mch_id',                coalesce(v_p.mch_id, ''),
    'appid',                 coalesce(v_p.appid, ''),
    'pay_status',            coalesce(v_p.status, ''),
    'wechat_transaction_id', coalesce(v_p.wechat_transaction_id, ''),
    'notified_at',           v_p.notified_at,
    'created_at',            v_p.created_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_get_order_payment_collection(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_get_order_payment_collection(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_get_order_payment_collection(text) TO authenticated;