-- ============================================================================
-- 商城履约 + 积分体系 批次 1b：六张新表
--
-- ⚠️ 本库 public schema 的默认权限是 anon=arwdDxtm（新表天生对匿名角色全量开放），
--    这正是此前 14 张表泄露的根因。因此每张新表都必须：
--      1) ENABLE ROW LEVEL SECURITY
--      2) 显式 REVOKE ALL FROM anon, authenticated
--      3) 再按最小面 GRANT
--    写操作一律走 SECURITY DEFINER 的 RPC，客户端只拿 SELECT，
--    以便把「唯一默认地址」「余额与流水同事务」等不变量锁在服务端。
-- ============================================================================

-- 当前登录者所属企业（根管理师）ID。SECURITY DEFINER 以避开 profiles 的 RLS 递归。
CREATE OR REPLACE FUNCTION public._my_root_manager_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(p.parent_manager_id, p.id)
  FROM public.profiles p
  WHERE p.id = auth.uid()
    AND p.role = 'manager';
$$;

GRANT EXECUTE ON FUNCTION public._my_root_manager_id() TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 1) user_shipping_addresses：收货地址簿
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_shipping_addresses (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  contact_name    text NOT NULL,
  contact_phone   text NOT NULL,
  province        text NOT NULL,
  city            text NOT NULL,
  district        text NOT NULL,
  address_detail  text NOT NULL,
  is_default      boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT usa_contact_name_check
    CHECK (btrim(contact_name) <> '' AND char_length(contact_name) <= 50),
  CONSTRAINT usa_contact_phone_check
    CHECK (contact_phone ~ '^1[3-9][0-9]{9}$'),
  CONSTRAINT usa_region_check
    CHECK (btrim(province) <> '' AND btrim(city) <> '' AND btrim(district) <> ''),
  CONSTRAINT usa_detail_check
    CHECK (btrim(address_detail) <> '' AND char_length(address_detail) <= 200)
);

-- 每人最多一个默认地址（数据库级不变量，切换默认必须在同事务内完成）
CREATE UNIQUE INDEX IF NOT EXISTS usa_one_default_per_user
  ON public.user_shipping_addresses (user_id)
  WHERE is_default = true;

CREATE INDEX IF NOT EXISTS usa_user_created_idx
  ON public.user_shipping_addresses (user_id, is_default DESC, created_at DESC);

ALTER TABLE public.user_shipping_addresses ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.user_shipping_addresses FROM anon;
REVOKE ALL ON TABLE public.user_shipping_addresses FROM authenticated;
GRANT SELECT ON TABLE public.user_shipping_addresses TO authenticated;
GRANT ALL ON TABLE public.user_shipping_addresses TO service_role;

CREATE POLICY usa_owner_select ON public.user_shipping_addresses
  FOR SELECT TO authenticated USING (user_id = auth.uid());

COMMENT ON TABLE public.user_shipping_addresses IS
  '用户收货地址簿。写入一律经 RPC，以保证「每人唯一默认地址」的不变量；下单时仍把地址快照写进 orders 的内联字段，历史订单不受地址后续修改影响。';


-- ─────────────────────────────────────────────────────────────
-- 2) points_balances：积分余额（每人一行，平台级单账户）
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.points_balances (
  user_id       uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  balance       integer NOT NULL DEFAULT 0,
  total_earned  integer NOT NULL DEFAULT 0,
  total_spent   integer NOT NULL DEFAULT 0,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pb_totals_nonneg CHECK (total_earned >= 0 AND total_spent >= 0)
);

-- 注意：故意不加 balance >= 0 约束。退款冲正必须按原奖励金额如实扣回，
-- 若在此截断为 0，用户就留下了并未真正获得的积分（可被反复刷）。
-- 余额允许短暂为负，由后续获取自然填平。

ALTER TABLE public.points_balances ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.points_balances FROM anon;
REVOKE ALL ON TABLE public.points_balances FROM authenticated;
GRANT SELECT ON TABLE public.points_balances TO authenticated;
GRANT ALL ON TABLE public.points_balances TO service_role;

CREATE POLICY pb_owner_select ON public.points_balances
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE POLICY pb_admin_select ON public.points_balances
  FOR SELECT TO authenticated USING (public.is_admin(auth.uid()));

COMMENT ON TABLE public.points_balances IS
  '积分余额缓存行。唯一真相是 points_ledger；本表由 _post_points_delta 在同事务内持行锁更新。故意不限制 balance >= 0，见列注释。';
COMMENT ON COLUMN public.points_balances.balance IS
  '当前可用积分。允许为负：退款冲正按原奖励金额如实扣回，截断为 0 会留下可被刷取的残余积分。';


-- ─────────────────────────────────────────────────────────────
-- 3) points_ledger：积分流水（只增不改，唯一真相）
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.points_ledger (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  delta            integer NOT NULL,
  balance_after    integer NOT NULL,
  reason_code      text NOT NULL,
  reason_text      text NOT NULL,
  ref_type         text,
  ref_id           uuid,
  operator_id      uuid,
  idempotency_key  text NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pl_delta_nonzero CHECK (delta <> 0),
  CONSTRAINT pl_reason_code_check CHECK (reason_code IN (
    'daily_weighing',
    'daily_login',
    'paid_order',
    'paid_order_reversal',
    'points_redeem',
    'points_redeem_refund',
    'manual_adjustment'
  )),
  CONSTRAINT pl_reason_text_check
    CHECK (btrim(reason_text) <> '' AND char_length(reason_text) <= 200),
  CONSTRAINT pl_manual_needs_operator
    CHECK (reason_code <> 'manual_adjustment' OR operator_id IS NOT NULL),
  CONSTRAINT pl_ref_pair_check
    CHECK ((ref_type IS NULL) = (ref_id IS NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS pl_idempotency_key_uidx
  ON public.points_ledger (idempotency_key);

CREATE INDEX IF NOT EXISTS pl_user_created_idx
  ON public.points_ledger (user_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS pl_ref_idx
  ON public.points_ledger (ref_type, ref_id)
  WHERE ref_id IS NOT NULL;

ALTER TABLE public.points_ledger ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.points_ledger FROM anon;
REVOKE ALL ON TABLE public.points_ledger FROM authenticated;
GRANT SELECT ON TABLE public.points_ledger TO authenticated;
GRANT ALL ON TABLE public.points_ledger TO service_role;

CREATE POLICY pl_owner_select ON public.points_ledger
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE POLICY pl_admin_select ON public.points_ledger
  FOR SELECT TO authenticated USING (public.is_admin(auth.uid()));

COMMENT ON TABLE public.points_ledger IS
  '积分流水，追加写、永不修改（由触发器无条件拒绝 UPDATE/DELETE）。每条都带变动值、变动后余额、机器原因码、中文原因、可选业务引用、操作人与幂等键。';
COMMENT ON COLUMN public.points_ledger.idempotency_key IS
  '幂等键，UNIQUE。每日称重用「用户+业务日」、每日登录用「用户+业务日」、订单奖励用「订单ID」、人工调整用「请求号」，重复提交只会命中同一行。';


-- ─────────────────────────────────────────────────────────────
-- 4) order_reviews：订单评价（阶段一不公开展示）
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.order_reviews (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    uuid NOT NULL UNIQUE REFERENCES public.orders(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  product_id  uuid,
  rating      smallint NOT NULL,
  content     text NOT NULL DEFAULT '',
  images      jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_public   boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT orv_rating_check CHECK (rating BETWEEN 1 AND 5),
  CONSTRAINT orv_content_check CHECK (char_length(content) <= 500),
  CONSTRAINT orv_images_check
    CHECK (jsonb_typeof(images) = 'array' AND jsonb_array_length(images) <= 6)
);

CREATE INDEX IF NOT EXISTS orv_user_created_idx
  ON public.order_reviews (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS orv_product_public_idx
  ON public.order_reviews (product_id, created_at DESC)
  WHERE is_public = true;

ALTER TABLE public.order_reviews ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.order_reviews FROM anon;
REVOKE ALL ON TABLE public.order_reviews FROM authenticated;
GRANT SELECT ON TABLE public.order_reviews TO authenticated;
GRANT ALL ON TABLE public.order_reviews TO service_role;

CREATE POLICY orv_owner_select ON public.order_reviews
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE POLICY orv_admin_select ON public.order_reviews
  FOR SELECT TO authenticated USING (public.is_admin(auth.uid()));

COMMENT ON TABLE public.order_reviews IS
  '订单评价。阶段一 is_public 恒为 false，只有提交者本人与商户（经商户订单 RPC）可见；将来要公开展示时只需切换 is_public 并新增公开读策略，无需改表结构。';


-- ─────────────────────────────────────────────────────────────
-- 5) order_return_requests：退货退款申请（双通道审批）
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.order_return_requests (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id            uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  user_id             uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  handler_scope       text NOT NULL,
  handler_manager_id  uuid,
  status              text NOT NULL DEFAULT 'pending',
  reason_code         text NOT NULL,
  reason_text         text NOT NULL,
  images              jsonb NOT NULL DEFAULT '[]'::jsonb,
  decided_by          uuid,
  decided_at          timestamptz,
  decision_note       text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT orr_handler_scope_check CHECK (handler_scope IN ('merchant', 'platform')),
  CONSTRAINT orr_status_check
    CHECK (status IN ('pending', 'approved', 'rejected', 'refunded', 'cancelled')),
  CONSTRAINT orr_merchant_needs_manager
    CHECK (handler_scope <> 'merchant' OR handler_manager_id IS NOT NULL),
  CONSTRAINT orr_platform_has_no_manager
    CHECK (handler_scope <> 'platform' OR handler_manager_id IS NULL),
  CONSTRAINT orr_reason_code_check CHECK (reason_code IN (
    'quality', 'wrong_item', 'damaged', 'not_as_described', 'no_longer_needed', 'other'
  )),
  CONSTRAINT orr_reason_text_check
    CHECK (btrim(reason_text) <> '' AND char_length(reason_text) <= 500),
  CONSTRAINT orr_decision_shape_check
    CHECK (status NOT IN ('approved', 'rejected')
           OR (decided_by IS NOT NULL AND decided_at IS NOT NULL)),
  CONSTRAINT orr_rejected_needs_note_check
    CHECK (status <> 'rejected'
           OR (decision_note IS NOT NULL AND btrim(decision_note) <> '')),
  CONSTRAINT orr_images_check
    CHECK (jsonb_typeof(images) = 'array' AND jsonb_array_length(images) <= 6)
);

-- 一个订单同时只能有一笔进行中的申请（已驳回/已取消可以重新申请）
CREATE UNIQUE INDEX IF NOT EXISTS orr_one_open_per_order
  ON public.order_return_requests (order_id)
  WHERE status IN ('pending', 'approved');

CREATE INDEX IF NOT EXISTS orr_user_created_idx
  ON public.order_return_requests (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS orr_manager_pending_idx
  ON public.order_return_requests (handler_manager_id, status, created_at DESC)
  WHERE handler_manager_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS orr_platform_pending_idx
  ON public.order_return_requests (status, created_at DESC)
  WHERE handler_scope = 'platform';

ALTER TABLE public.order_return_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.order_return_requests FROM anon;
REVOKE ALL ON TABLE public.order_return_requests FROM authenticated;
GRANT SELECT ON TABLE public.order_return_requests TO authenticated;
GRANT ALL ON TABLE public.order_return_requests TO service_role;

CREATE POLICY orr_owner_select ON public.order_return_requests
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE POLICY orr_admin_select ON public.order_return_requests
  FOR SELECT TO authenticated USING (public.is_admin(auth.uid()));

COMMENT ON TABLE public.order_return_requests IS
  '退货退款申请。handler_scope 由服务端按订单实际收款方判定，绝不接受客户端传入：merchant 走商户微信退款链路自动闭环；platform 由平台后台同意后，需人工到支付平台后台执行退款，订单只能由网关回调改成 refunded。';
COMMENT ON COLUMN public.order_return_requests.status IS
  'pending 待审核 / approved 已同意待退款 / rejected 已驳回 / refunded 已退款(仅由网关回调驱动的触发器写入) / cancelled 用户撤回。任何人工操作都不得直接写 refunded。';


-- ─────────────────────────────────────────────────────────────
-- 6) merchant_module_grants：商城新模块的按商户授权
--    完全沿用 oem_device_grants 的两级模型：平台授予 + 商户自开关
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.merchant_module_grants (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  manager_id    uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  module_key    text NOT NULL,
  grant_status  text NOT NULL DEFAULT 'granted',
  is_enabled    boolean NOT NULL DEFAULT false,
  granted_by    uuid,
  granted_at    timestamptz NOT NULL DEFAULT now(),
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT mmg_module_key_check
    CHECK (module_key IN ('shop_order_lifecycle', 'points_exchange')),
  CONSTRAINT mmg_grant_status_check
    CHECK (grant_status IN ('granted', 'revoked')),
  CONSTRAINT mmg_unique_per_manager UNIQUE (manager_id, module_key)
);

ALTER TABLE public.merchant_module_grants ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.merchant_module_grants FROM anon;
REVOKE ALL ON TABLE public.merchant_module_grants FROM authenticated;
GRANT SELECT ON TABLE public.merchant_module_grants TO authenticated;
GRANT ALL ON TABLE public.merchant_module_grants TO service_role;

CREATE POLICY mmg_admin_select ON public.merchant_module_grants
  FOR SELECT TO authenticated USING (public.is_admin(auth.uid()));

CREATE POLICY mmg_manager_select_own ON public.merchant_module_grants
  FOR SELECT TO authenticated
  USING (manager_id = public._my_root_manager_id());

COMMENT ON TABLE public.merchant_module_grants IS
  '商城新模块（订单履约、积分兑换）的按企业授权。两级：grant_status 由平台授予/回收，is_enabled 由商户自己开关，二者同时成立才对 C 端开放。默认不开。写入一律经 RPC。';