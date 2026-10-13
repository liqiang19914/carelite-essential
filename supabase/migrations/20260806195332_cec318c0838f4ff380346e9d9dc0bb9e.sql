-- ═══════════════════════════════════════════════════════════════════
-- 商户订单记录与微信退款：列表索引 + 退款流水表
-- ═══════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 商户订单列表主路径：先按归属过滤，再按 (created_at, id) 倒序做键集翻页。
-- 归属列可为 NULL（平台自营商品），这类订单永远不属于任何商户，直接排除出索引。
CREATE INDEX IF NOT EXISTS idx_orders_owner_created
  ON public.orders (owner_manager_id_snapshot, created_at DESC, id DESC)
  WHERE owner_manager_id_snapshot IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_orders_owner_status_created
  ON public.orders (owner_manager_id_snapshot, status, created_at DESC, id DESC)
  WHERE owner_manager_id_snapshot IS NOT NULL;

-- 商品名模糊搜索：搜索永远叠在归属过滤之上，走位图与上面的索引相交
CREATE INDEX IF NOT EXISTS idx_orders_title_trgm
  ON public.orders USING gin (product_title_snapshot gin_trgm_ops);

-- ─── 退款主表：本期只做全额退款，因此一笔订单最多一条退款记录 ───
CREATE TABLE IF NOT EXISTS public.wechat_miniapp_refunds (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL UNIQUE REFERENCES public.orders(id) ON DELETE RESTRICT,
  out_trade_no text NOT NULL UNIQUE,
  out_refund_no text NOT NULL UNIQUE,
  -- 收款时那条支付单的完整凭证快照。退款必须用「当初收这笔钱的那套商户凭证」发起，
  -- 商户后来换了商户号也不能影响历史订单的退款，因此这里做整组外键而不是各存一列。
  pay_order_id uuid NOT NULL,
  pay_account_id uuid NOT NULL,
  credential_version_id uuid NOT NULL,
  payee_manager_id uuid NOT NULL,
  refund_amount_cents integer NOT NULL CHECK (refund_amount_cents > 0),
  total_amount_cents integer NOT NULL CHECK (total_amount_cents > 0),
  reason text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'success', 'closed', 'abnormal', 'failed')),
  wechat_refund_id text NOT NULL DEFAULT '',
  failure_summary text NOT NULL DEFAULT '',
  -- 提交租约：同一笔退款在租约到期前不允许被第二次提交到微信
  submit_lease_until timestamptz,
  submitted_at timestamptz,
  succeeded_at timestamptz,
  requested_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  requested_by_name text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT wmr_full_refund_only CHECK (refund_amount_cents = total_amount_cents),
  CONSTRAINT wmr_pay_snapshot_fkey FOREIGN KEY
    (pay_order_id, pay_account_id, credential_version_id, payee_manager_id)
    REFERENCES public.wechat_miniapp_pay_orders (id, pay_account_id, credential_version_id, payee_manager_id)
    ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_wmr_payee_created
  ON public.wechat_miniapp_refunds (payee_manager_id, created_at DESC);

-- 在途退款的巡检路径
CREATE INDEX IF NOT EXISTS idx_wmr_inflight
  ON public.wechat_miniapp_refunds (status, updated_at DESC)
  WHERE status IN ('pending', 'processing');

-- ─── 退款事件流水：请求 / 主动查询 / 回调各自留痕，用于幂等与排查 ───
CREATE TABLE IF NOT EXISTS public.wechat_miniapp_refund_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  refund_id uuid NOT NULL REFERENCES public.wechat_miniapp_refunds(id) ON DELETE CASCADE,
  source text NOT NULL CHECK (source IN ('request', 'query', 'notify')),
  -- 同一来源同一事件只记一次：微信回调会重复推送，这里是幂等的落点
  event_key text NOT NULL,
  refund_status text NOT NULL DEFAULT '',
  wechat_refund_id text NOT NULL DEFAULT '',
  summary text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT wmre_event_uidx UNIQUE (refund_id, source, event_key)
);

CREATE INDEX IF NOT EXISTS idx_wmre_refund_created
  ON public.wechat_miniapp_refund_events (refund_id, created_at DESC);

-- ─── 访问边界：两张表只允许 service_role 与 SECURITY DEFINER 函数进入 ───
ALTER TABLE public.wechat_miniapp_refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wechat_miniapp_refund_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.wechat_miniapp_refunds FROM PUBLIC;
REVOKE ALL ON TABLE public.wechat_miniapp_refunds FROM anon;
REVOKE ALL ON TABLE public.wechat_miniapp_refunds FROM authenticated;
REVOKE ALL ON TABLE public.wechat_miniapp_refund_events FROM PUBLIC;
REVOKE ALL ON TABLE public.wechat_miniapp_refund_events FROM anon;
REVOKE ALL ON TABLE public.wechat_miniapp_refund_events FROM authenticated;