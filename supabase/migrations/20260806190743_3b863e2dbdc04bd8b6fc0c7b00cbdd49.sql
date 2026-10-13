-- ============================================================================
-- 每 OEM 商户独立微信支付收款：支付账户表 + 不可变凭证版本表 + 支付单收款方快照
--
-- 设计要点：
--  1. 与 manager_miniprograms（小程序身份/品牌）彻底分开：支付凭证是另一套凭证体系，
--     且需要「只写不读」语义，而 get_manager_oem_config 是明文回传 app_secret 的。
--  2. 账户表存「正在编辑的草稿」，允许部分为空以表达配置不完整；
--     只有自检通过后冻结出的不可变 version 才能给新订单使用。
--  3. 凭证轮换后旧 version 永久保留 —— 否则商户换一次密钥，在途订单的回调
--     就会解密失败，表现为「顾客钱付了、订单永远未付款」。
--  4. 所有表级 DML 权限一律回收，写入只能走 SECURITY DEFINER RPC。
-- ============================================================================

CREATE TABLE public.manager_wechat_pay_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- 必须是企业根管理师（profiles.parent_manager_id 为空）。该约束需要子查询，
  -- 无法用 CHECK 表达，由 RPC 层强制；表级 DML 已全部回收，RPC 是唯一入口。
  manager_id uuid NOT NULL UNIQUE
    REFERENCES public.managers(id) ON DELETE RESTRICT,

  mch_id text,
  api_v3_key text,
  merchant_private_key_pem text,
  merchant_cert_serial_no text,
  wechatpay_public_key_id text,
  wechatpay_public_key_pem text,

  is_enabled boolean NOT NULL DEFAULT false,
  config_revision bigint NOT NULL DEFAULT 0,
  active_credential_version_id uuid,

  verification_status text NOT NULL DEFAULT 'unconfigured'
    CHECK (verification_status IN ('unconfigured','incomplete','unchecked','passed','failed')),
  verification_summary text NOT NULL DEFAULT '',
  verification_warnings text[] NOT NULL DEFAULT '{}',
  last_checked_at timestamptz,

  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  updated_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT mwpa_mch_id_digits CHECK (mch_id IS NULL OR mch_id ~ '^[0-9]+$'),
  -- 32 字符「且」32 字节：挡住 32 个中文字符——TextEncoder 编码后远超 32 字节，
  -- 会让 Edge Function 里的 crypto.subtle.importKey 直接抛错。
  CONSTRAINT mwpa_api_v3_key_len CHECK (
    api_v3_key IS NULL
    OR (char_length(api_v3_key) = 32 AND octet_length(api_v3_key) = 32)
  ),
  CONSTRAINT mwpa_private_key_nonblank CHECK (
    merchant_private_key_pem IS NULL OR length(btrim(merchant_private_key_pem)) > 0
  ),
  CONSTRAINT mwpa_cert_serial_nonblank CHECK (
    merchant_cert_serial_no IS NULL OR length(btrim(merchant_cert_serial_no)) > 0
  ),
  CONSTRAINT mwpa_pubkey_id_prefix CHECK (
    wechatpay_public_key_id IS NULL OR wechatpay_public_key_id LIKE 'PUB\_KEY\_ID\_%'
  ),
  CONSTRAINT mwpa_pubkey_pem_nonblank CHECK (
    wechatpay_public_key_pem IS NULL OR length(btrim(wechatpay_public_key_pem)) > 0
  )
);

COMMENT ON TABLE public.manager_wechat_pay_accounts IS
  'OEM 商户直连微信支付账户（草稿态）。一个企业根一行；secret 列只写不读，读取只经 RPC 返回 has_* 布尔。';
COMMENT ON COLUMN public.manager_wechat_pay_accounts.config_revision IS
  '任何凭证/配置变化即递增；自检落库时用它守卫，防止「检的是旧配置、激活的是并发保存后的新配置」。';
COMMENT ON COLUMN public.manager_wechat_pay_accounts.active_credential_version_id IS
  '只有自检通过冻结出的不可变 version 能成为新订单的有效凭证；配置一改即清空。';

-- 两个企业根不能同时占用同一商户号；同企业多个 OEM AppID 共享一条支付账户是允许的
CREATE UNIQUE INDEX manager_wechat_pay_accounts_mch_id_uidx
  ON public.manager_wechat_pay_accounts (mch_id) WHERE mch_id IS NOT NULL;


CREATE TABLE public.manager_wechat_pay_credential_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pay_account_id uuid NOT NULL
    REFERENCES public.manager_wechat_pay_accounts(id) ON DELETE RESTRICT,
  config_revision bigint NOT NULL,

  mch_id text NOT NULL,
  api_v3_key text NOT NULL,
  merchant_private_key_pem text NOT NULL,
  merchant_cert_serial_no text NOT NULL,
  wechatpay_public_key_id text,
  wechatpay_public_key_pem text,

  -- 192 位随机，仅用于回调路由定位（微信 notify_url 禁带查询串，只能走路径段）。
  -- 绝不作为身份凭证：回调仍须完成签名验证 + 解密 + 快照一致性校验。
  notify_token text NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(24), 'hex'),

  verified_at timestamptz NOT NULL DEFAULT now(),
  verification_warnings text[] NOT NULL DEFAULT '{}',
  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT mwpcv_account_revision_uniq UNIQUE (pay_account_id, config_revision),
  -- 供 accounts.active_credential_version_id 与退款表做复合外键引用
  CONSTRAINT mwpcv_id_account_uniq UNIQUE (id, pay_account_id),

  CONSTRAINT mwpcv_mch_id_digits CHECK (mch_id ~ '^[0-9]+$'),
  CONSTRAINT mwpcv_api_v3_key_len CHECK (
    char_length(api_v3_key) = 32 AND octet_length(api_v3_key) = 32
  ),
  CONSTRAINT mwpcv_private_key_nonblank CHECK (length(btrim(merchant_private_key_pem)) > 0),
  CONSTRAINT mwpcv_cert_serial_nonblank CHECK (length(btrim(merchant_cert_serial_no)) > 0),
  CONSTRAINT mwpcv_pubkey_paired CHECK (
    (wechatpay_public_key_id IS NULL AND wechatpay_public_key_pem IS NULL)
    OR (wechatpay_public_key_id LIKE 'PUB\_KEY\_ID\_%'
        AND length(btrim(wechatpay_public_key_pem)) > 0)
  )
);

COMMENT ON TABLE public.manager_wechat_pay_credential_versions IS
  '自检通过后冻结的不可变凭证快照，只增不改。查单与回调永远用创建预支付单时绑定的版本，绝不按当前配置重新推导。';

CREATE INDEX manager_wechat_pay_versions_mch_id_idx
  ON public.manager_wechat_pay_credential_versions (mch_id);

ALTER TABLE public.manager_wechat_pay_accounts
  ADD CONSTRAINT manager_wechat_pay_accounts_active_version_fkey
  FOREIGN KEY (active_credential_version_id, id)
  REFERENCES public.manager_wechat_pay_credential_versions(id, pay_account_id)
  DEFERRABLE INITIALLY DEFERRED;


-- ─── 支付单收款方快照（该表当前 0 行，无回填成本） ───────────────────────────
ALTER TABLE public.wechat_miniapp_pay_orders
  ADD COLUMN payee_type text NOT NULL DEFAULT 'platform'
    CHECK (payee_type IN ('platform','manager')),
  ADD COLUMN payee_manager_id uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  ADD COLUMN pay_account_id uuid
    REFERENCES public.manager_wechat_pay_accounts(id) ON DELETE RESTRICT,
  ADD COLUMN credential_version_id uuid,
  ADD COLUMN notify_url_snapshot text NOT NULL DEFAULT '';

ALTER TABLE public.wechat_miniapp_pay_orders
  ADD CONSTRAINT wechat_miniapp_pay_orders_version_account_fkey
  FOREIGN KEY (credential_version_id, pay_account_id)
  REFERENCES public.manager_wechat_pay_credential_versions(id, pay_account_id)
  ON DELETE RESTRICT;

ALTER TABLE public.wechat_miniapp_pay_orders
  ADD CONSTRAINT wechat_miniapp_pay_orders_payee_shape_check CHECK (
    (payee_type = 'platform' AND payee_manager_id IS NULL
      AND pay_account_id IS NULL AND credential_version_id IS NULL)
    OR
    (payee_type = 'manager' AND payee_manager_id IS NOT NULL
      AND pay_account_id IS NOT NULL AND credential_version_id IS NOT NULL)
  );

-- 供退款表引用：保证退款单引用的 version 确属同一支付账户与同一收款方
ALTER TABLE public.wechat_miniapp_pay_orders
  ADD CONSTRAINT wechat_miniapp_pay_orders_refund_snapshot_uidx
  UNIQUE (id, pay_account_id, credential_version_id, payee_manager_id);

COMMENT ON COLUMN public.wechat_miniapp_pay_orders.credential_version_id IS
  '创建预支付单时绑定的不可变凭证版本；/query 与回调必须用它，不得按订单归属重新解析当前凭证。';


-- ─── RLS 与权限：读取只经 RPC，表级 DML 全部回收 ────────────────────────────
ALTER TABLE public.manager_wechat_pay_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manager_wechat_pay_credential_versions ENABLE ROW LEVEL SECURITY;

-- 防御性 SELECT policy：即便将来误授了表级 SELECT，也只能看到自己那行。
-- 注意：本轮不向 authenticated 授予任何表级 SELECT，私钥/APIv3 拿不到。
CREATE POLICY mwpa_admin_select ON public.manager_wechat_pay_accounts
  FOR SELECT TO authenticated
  USING (public.is_admin(auth.uid()));

CREATE POLICY mwpa_self_select ON public.manager_wechat_pay_accounts
  FOR SELECT TO authenticated
  USING (manager_id = auth.uid());

-- 版本表不建任何客户端 policy：仅 service_role 可达

REVOKE ALL ON public.manager_wechat_pay_accounts FROM PUBLIC;
REVOKE ALL ON public.manager_wechat_pay_accounts FROM anon;
REVOKE ALL ON public.manager_wechat_pay_accounts FROM authenticated;
REVOKE ALL ON public.manager_wechat_pay_credential_versions FROM PUBLIC;
REVOKE ALL ON public.manager_wechat_pay_credential_versions FROM anon;
REVOKE ALL ON public.manager_wechat_pay_credential_versions FROM authenticated;