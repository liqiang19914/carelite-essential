-- ───────────────────────────── 推广 / 佣金 / 提现 数据表 ─────────────────────────────

CREATE TABLE IF NOT EXISTS public.promotion_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  enterprise_root_id uuid NOT NULL,
  inviter_points integer NOT NULL DEFAULT 0,
  invitee_points integer NOT NULL DEFAULT 0,
  commission_mode text NOT NULL DEFAULT 'none' CHECK (commission_mode IN ('none','rate','fixed')),
  commission_rate_bps integer NOT NULL DEFAULT 0 CHECK (commission_rate_bps >= 0 AND commission_rate_bps <= 5000),
  commission_fixed_cents integer NOT NULL DEFAULT 0 CHECK (commission_fixed_cents >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT promotion_rules_enterprise_unique UNIQUE (enterprise_root_id)
);

CREATE TABLE IF NOT EXISTS public.promotion_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  enterprise_root_id uuid NOT NULL,
  promoter_id uuid NOT NULL,
  short_code text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT promotion_codes_enterprise_promoter_unique UNIQUE (enterprise_root_id, promoter_id),
  CONSTRAINT promotion_codes_short_code_unique UNIQUE (short_code)
);

CREATE TABLE IF NOT EXISTS public.promoter_bindings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  enterprise_root_id uuid NOT NULL,
  promoter_id uuid NOT NULL,
  client_id uuid NOT NULL,
  order_count integer NOT NULL DEFAULT 0,
  total_commission_cents integer NOT NULL DEFAULT 0,
  bound_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT promoter_bindings_enterprise_client_unique UNIQUE (enterprise_root_id, client_id),
  CONSTRAINT promoter_bindings_self_check CHECK (promoter_id <> client_id)
);

CREATE TABLE IF NOT EXISTS public.commission_accounts (
  profile_id uuid PRIMARY KEY,
  balance_cents integer NOT NULL DEFAULT 0,
  reserved_cents integer NOT NULL DEFAULT 0,
  total_earned_cents integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.commission_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  delta_cents integer NOT NULL,
  balance_after_cents integer NOT NULL,
  kind text NOT NULL CHECK (kind IN ('commission','reversal','withdrawal_reserve','withdrawal_release','paid_out')),
  ref_type text,
  ref_id uuid,
  idempotency_key text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commission_ledger_idempotency_unique UNIQUE (idempotency_key)
);

CREATE TABLE IF NOT EXISTS public.withdrawal_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  enterprise_root_id uuid NOT NULL,
  amount_cents integer NOT NULL CHECK (amount_cents > 0),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','paid')),
  note text NOT NULL DEFAULT '',
  dedupe_key text NOT NULL,
  reviewed_by uuid,
  reviewed_at timestamptz,
  paid_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT withdrawal_requests_dedupe_unique UNIQUE (dedupe_key)
);

-- ───────────────────────────── 抽奖 数据表 ─────────────────────────────

CREATE TABLE IF NOT EXISTS public.lottery_activities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  enterprise_root_id uuid NOT NULL,
  title text NOT NULL,
  display_type text NOT NULL DEFAULT 'wheel' CHECK (display_type IN ('wheel','grid')),
  description text NOT NULL DEFAULT '',
  start_at timestamptz NOT NULL,
  end_at timestamptz NOT NULL,
  daily_limit integer NOT NULL DEFAULT 1 CHECK (daily_limit >= 1 AND daily_limit <= 100),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lottery_activities_time_check CHECK (end_at > start_at)
);

CREATE TABLE IF NOT EXISTS public.lottery_prizes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  activity_id uuid NOT NULL REFERENCES public.lottery_activities(id) ON DELETE CASCADE,
  name text NOT NULL,
  prize_type text NOT NULL CHECK (prize_type IN ('points','product')),
  product_id uuid,
  points integer NOT NULL DEFAULT 0 CHECK (points >= 0),
  weight_bps integer NOT NULL CHECK (weight_bps >= 0 AND weight_bps <= 10000),
  total_stock integer NOT NULL CHECK (total_stock >= 0),
  remaining_stock integer NOT NULL CHECK (remaining_stock >= 0),
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.lottery_draw_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  activity_id uuid NOT NULL REFERENCES public.lottery_activities(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  prize_id uuid,
  won boolean NOT NULL DEFAULT false,
  idempotency_key text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lottery_draw_records_idem_unique UNIQUE (idempotency_key)
);

CREATE TABLE IF NOT EXISTS public.lottery_claim_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  draw_record_id uuid NOT NULL REFERENCES public.lottery_draw_records(id) ON DELETE CASCADE,
  prize_type text NOT NULL CHECK (prize_type IN ('points','product')),
  product_id uuid,
  contact_phone text NOT NULL DEFAULT '',
  shipping_name text NOT NULL DEFAULT '',
  shipping_province text NOT NULL DEFAULT '',
  shipping_city text NOT NULL DEFAULT '',
  shipping_district text NOT NULL DEFAULT '',
  shipping_address_detail text NOT NULL DEFAULT '',
  claimed_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lottery_claim_records_draw_unique UNIQUE (draw_record_id)
);

-- ───────────────────────────── 索引 ─────────────────────────────

CREATE INDEX IF NOT EXISTS promotion_codes_enterprise_idx ON public.promotion_codes (enterprise_root_id, is_active);
CREATE INDEX IF NOT EXISTS promoter_bindings_promoter_idx ON public.promoter_bindings (enterprise_root_id, promoter_id);
CREATE INDEX IF NOT EXISTS promoter_bindings_client_idx ON public.promoter_bindings (client_id);
CREATE INDEX IF NOT EXISTS commission_ledger_account_idx ON public.commission_ledger (account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS withdrawal_requests_enterprise_idx ON public.withdrawal_requests (enterprise_root_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS withdrawal_requests_account_idx ON public.withdrawal_requests (account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS lottery_activities_enterprise_idx ON public.lottery_activities (enterprise_root_id, is_active, end_at);
CREATE INDEX IF NOT EXISTS lottery_prizes_activity_idx ON public.lottery_prizes (activity_id, sort_order);
CREATE INDEX IF NOT EXISTS lottery_draw_records_user_idx ON public.lottery_draw_records (activity_id, user_id, created_at DESC);

-- ───────────────────────────── RLS：全部新表默认拒绝直连，访问一律走服务端函数 ─────────────────────────────

ALTER TABLE public.promotion_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.promotion_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.promoter_bindings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commission_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.commission_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.withdrawal_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lottery_activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lottery_prizes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lottery_draw_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lottery_claim_records ENABLE ROW LEVEL SECURITY;

-- ───────────────────────────── 订单推广快照列 ─────────────────────────────

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS promoter_id_snapshot uuid,
  ADD COLUMN IF NOT EXISTS promoter_code_snapshot text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS commission_cents_snapshot integer NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS orders_promoter_snapshot_idx ON public.orders (promoter_id_snapshot, status);

-- ───────────────────────────── 权限定义 ─────────────────────────────

INSERT INTO public.permission_definitions (code, name, node_level, parent_code, permission_kind, sort_order, description)
VALUES
  ('marketing_center', '营销中心', 1, NULL, 'menu', 900, '推广、抽奖等营销能力'),
  ('marketing_withdrawals', '佣金提现审核', 2, 'marketing_center', 'action', 10, '审核推广人的佣金提现申请并标记打款')
ON CONFLICT (code) DO NOTHING;

-- 存量角色回填：有 shop 或 orders 权限的角色补 marketing_center；同一角色补 marketing_withdrawals
INSERT INTO public.enterprise_role_permissions (role_id, permission_code)
SELECT rp.role_id, 'marketing_center'
FROM public.enterprise_role_permissions rp
WHERE rp.permission_code IN ('shop', 'orders')
ON CONFLICT DO NOTHING;

INSERT INTO public.enterprise_role_permissions (role_id, permission_code)
SELECT rp.role_id, 'marketing_withdrawals'
FROM public.enterprise_role_permissions rp
WHERE rp.permission_code IN ('shop', 'orders')
ON CONFLICT DO NOTHING;