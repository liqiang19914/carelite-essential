-- ============================================================================
-- 门店体系数据层：四张新表 + 商品/订单扩展 + 模块授权键
-- 写操作一律走 SECURITY DEFINER RPC / Edge Function，客户端仅最小 SELECT。
-- ============================================================================

-- ── 0. 门店模块双闸门 helper：平台授予 + 商户自开关 ─────────────────
CREATE OR REPLACE FUNCTION public._store_module_on(p_root uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.merchant_module_grants g
    WHERE g.manager_id = p_root
      AND g.module_key = 'stores'
      AND g.grant_status = 'granted'
      AND g.is_enabled = true
  );
$function$;

REVOKE ALL ON FUNCTION public._store_module_on(uuid) FROM PUBLIC;

-- ── 1. stores：门店实体 ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.stores (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id     uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  operator_user_id    uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  short_code          text NOT NULL,
  name                text NOT NULL,
  phone               text NOT NULL,
  status              text NOT NULL DEFAULT 'active',
  receipt_qr_url      text NOT NULL DEFAULT '',
  payment_merchant_no text NOT NULL DEFAULT '',
  created_source      text NOT NULL DEFAULT 'merchant',
  disabled_at         timestamptz,
  created_by          uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT stores_short_code_uniq UNIQUE (short_code),
  CONSTRAINT stores_name_check CHECK (btrim(name) <> '' AND char_length(name) <= 60),
  CONSTRAINT stores_phone_check CHECK (phone ~ '^1[3-9][0-9]{9}$'),
  CONSTRAINT stores_status_check CHECK (status IN ('active','disabled')),
  CONSTRAINT stores_created_source_check CHECK (created_source IN ('merchant','application'))
);

CREATE INDEX IF NOT EXISTS idx_stores_root_status
  ON public.stores (root_manager_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_stores_operator
  ON public.stores (operator_user_id) WHERE operator_user_id IS NOT NULL;

ALTER TABLE public.stores ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.stores FROM anon;
REVOKE ALL ON TABLE public.stores FROM authenticated;
GRANT SELECT ON TABLE public.stores TO authenticated;
GRANT ALL ON TABLE public.stores TO service_role;

CREATE POLICY stores_operator_select ON public.stores
  FOR SELECT TO authenticated USING (operator_user_id = auth.uid());

CREATE POLICY stores_merchant_select ON public.stores
  FOR SELECT TO authenticated USING (root_manager_id = public._my_root_manager_id());

CREATE POLICY stores_admin_select ON public.stores
  FOR SELECT TO authenticated USING (public.is_admin(auth.uid()));

COMMENT ON TABLE public.stores IS
  '门店实体：root_manager_id 归属企业根；operator_user_id 是经营账号（客户身份+经营授权，不新增角色）。短码一经创建不变，门店只停用不删除。';

-- ── 2. store_product_grants：门店商品子集授权 ────────────────────
CREATE TABLE IF NOT EXISTS public.store_product_grants (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id   uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  is_enabled boolean NOT NULL DEFAULT true,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT spg_store_product_uniq UNIQUE (store_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_spg_product
  ON public.store_product_grants (product_id) WHERE is_enabled = true;

ALTER TABLE public.store_product_grants ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.store_product_grants FROM anon;
REVOKE ALL ON TABLE public.store_product_grants FROM authenticated;
GRANT SELECT ON TABLE public.store_product_grants TO authenticated;
GRANT ALL ON TABLE public.store_product_grants TO service_role;

CREATE POLICY spg_merchant_select ON public.store_product_grants
  FOR SELECT TO authenticated
  USING (store_id IN (SELECT id FROM public.stores WHERE root_manager_id = public._my_root_manager_id()));

CREATE POLICY spg_operator_select ON public.store_product_grants
  FOR SELECT TO authenticated
  USING (store_id IN (SELECT id FROM public.stores WHERE operator_user_id = auth.uid()));

CREATE POLICY spg_admin_select ON public.store_product_grants
  FOR SELECT TO authenticated USING (public.is_admin(auth.uid()));

COMMENT ON TABLE public.store_product_grants IS
  '门店商品子集授权：总部给每个门店勾选可卖商品。写入一律经 RPC，校验商品属于本企业根。';

-- ── 3. merchant_store_applications：C 端入驻申请 ─────────────────
CREATE TABLE IF NOT EXISTS public.merchant_store_applications (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id   uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  applicant_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  store_name        text NOT NULL,
  contact_name      text NOT NULL,
  contact_phone     text NOT NULL,
  status            text NOT NULL DEFAULT 'pending',
  rejection_reason  text NOT NULL DEFAULT '',
  reviewed_by       uuid,
  reviewed_at       timestamptz,
  created_store_id  uuid REFERENCES public.stores(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT msa_status_check CHECK (status IN ('pending','approved','rejected','cancelled')),
  CONSTRAINT msa_name_check CHECK (btrim(store_name) <> '' AND char_length(store_name) <= 60),
  CONSTRAINT msa_phone_check CHECK (contact_phone ~ '^1[3-9][0-9]{9}$')
);

CREATE UNIQUE INDEX IF NOT EXISTS msa_one_pending_per_user_root
  ON public.merchant_store_applications (root_manager_id, applicant_user_id)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_msa_root_status_created
  ON public.merchant_store_applications (root_manager_id, status, created_at DESC);

ALTER TABLE public.merchant_store_applications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.merchant_store_applications FROM anon;
REVOKE ALL ON TABLE public.merchant_store_applications FROM authenticated;
GRANT SELECT ON TABLE public.merchant_store_applications TO authenticated;
GRANT ALL ON TABLE public.merchant_store_applications TO service_role;

CREATE POLICY msa_applicant_select ON public.merchant_store_applications
  FOR SELECT TO authenticated USING (applicant_user_id = auth.uid());

CREATE POLICY msa_merchant_select ON public.merchant_store_applications
  FOR SELECT TO authenticated USING (root_manager_id = public._my_root_manager_id());

CREATE POLICY msa_admin_select ON public.merchant_store_applications
  FOR SELECT TO authenticated USING (public.is_admin(auth.uid()));

COMMENT ON TABLE public.merchant_store_applications IS
  'C 端入驻申请：申请人已登录，审核通过即成为该店经营者，不采集密码。';

-- ── 4. merchant_consult_settings：商户级商城咨询配置 ──────────────
CREATE TABLE IF NOT EXISTS public.merchant_consult_settings (
  root_manager_id         uuid PRIMARY KEY REFERENCES public.managers(id) ON DELETE CASCADE,
  channels                text[] NOT NULL DEFAULT '{}',
  ai_manager_id           uuid REFERENCES public.managers(id) ON DELETE SET NULL,
  human_handoff_enabled   boolean NOT NULL DEFAULT false,
  wecom_qr_url            text NOT NULL DEFAULT '',
  wecom_acquisition_url   text NOT NULL DEFAULT '',
  miniapp_contact_enabled boolean NOT NULL DEFAULT false,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.merchant_consult_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.merchant_consult_settings FROM anon;
REVOKE ALL ON TABLE public.merchant_consult_settings FROM authenticated;
GRANT SELECT ON TABLE public.merchant_consult_settings TO authenticated;
GRANT ALL ON TABLE public.merchant_consult_settings TO service_role;

CREATE POLICY mcs_merchant_select ON public.merchant_consult_settings
  FOR SELECT TO authenticated USING (root_manager_id = public._my_root_manager_id());

CREATE POLICY mcs_admin_select ON public.merchant_consult_settings
  FOR SELECT TO authenticated USING (public.is_admin(auth.uid()));

COMMENT ON TABLE public.merchant_consult_settings IS
  '商户级商城咨询配置：channels ∈ ai/miniapp_contact/wecom_qr/wecom_acquisition，可多选组合。ai_manager_id 是承接商城咨询的本企业健管师。';

-- ── 5. products：仅门店销售标记（渠道维度，与计价维度正交）──────
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS store_only boolean NOT NULL DEFAULT false;

-- ── 6. orders：线下门店订单状态机 ─────────────────────────────────
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS store_id uuid REFERENCES public.stores(id) ON DELETE SET NULL;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS payment_channel text NOT NULL DEFAULT 'online';
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS offline_status text;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS offline_claimed_at timestamptz;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS verified_by uuid;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS verified_at timestamptz;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS store_name_snapshot text NOT NULL DEFAULT '';
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS receipt_qr_url_snapshot text NOT NULL DEFAULT '';

ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_payment_channel_check;
ALTER TABLE public.orders ADD CONSTRAINT orders_payment_channel_check
  CHECK (payment_channel IN ('online','offline_store'));
ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_offline_status_check;
ALTER TABLE public.orders ADD CONSTRAINT orders_offline_status_check
  CHECK (offline_status IS NULL OR offline_status IN ('awaiting_payment','awaiting_verification','verified','cancelled'));

CREATE INDEX IF NOT EXISTS idx_orders_store_status
  ON public.orders (store_id, offline_status, created_at DESC) WHERE store_id IS NOT NULL;

-- ── 7. 公开问答消息角色扩 'manager'（人工回复）──────────────────
ALTER TABLE public.manager_public_qa_messages DROP CONSTRAINT IF EXISTS manager_public_qa_messages_role_check;
ALTER TABLE public.manager_public_qa_messages ADD CONSTRAINT manager_public_qa_messages_role_check
  CHECK (role IN ('user','assistant','manager'));

-- ── 8. 门店模块授权键（扩 CHECK，覆盖存量可见性键）────────────────
ALTER TABLE public.merchant_module_grants DROP CONSTRAINT IF EXISTS mmg_module_key_check;
ALTER TABLE public.merchant_module_grants ADD CONSTRAINT mmg_module_key_check
  CHECK (module_key IN ('shop_order_lifecycle','points_exchange','stores','view_conversations','view_health_insights','view_health_records'));