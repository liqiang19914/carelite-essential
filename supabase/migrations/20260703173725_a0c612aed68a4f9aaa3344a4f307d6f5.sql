-- ============================================================
-- 套餐分级系统：membership_plans 配置表 + managers 套餐字段
-- ============================================================

CREATE TABLE public.membership_plans (
  code text PRIMARY KEY,
  display_name text NOT NULL,
  sort_order integer NOT NULL,
  manager_seat_limit integer NOT NULL,
  client_limit integer NOT NULL,
  ai_insight_monthly_limit integer NULL, -- NULL = 不限次数
  knowledge_doc_limit_per_manager integer NOT NULL,
  enterprise_center_enabled boolean NOT NULL DEFAULT false,
  shop_live_enabled boolean NOT NULL DEFAULT false,
  hard_enforce_numeric_limits boolean NOT NULL DEFAULT true, -- false = 仅展示不拦截（免费版）
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.membership_plans IS '套餐分级配置表：5档套餐的坐席数/客户数/AI洞察次数/知识库容量/功能开关，作为唯一权威数据源';

INSERT INTO public.membership_plans
  (code, display_name, sort_order, manager_seat_limit, client_limit, ai_insight_monthly_limit, knowledge_doc_limit_per_manager, enterprise_center_enabled, shop_live_enabled, hard_enforce_numeric_limits)
VALUES
  ('free',       '免费版', 1, 1,  20,   5,    5,   false, false, false),
  ('basic',      '基础版', 2, 1,  100,  30,   20,  false, false, true),
  ('advanced',   '高级版', 3, 3,  300,  NULL, 50,  true,  false, true),
  ('enterprise', '企业版', 4, 5,  500,  NULL, 50,  true,  false, true),
  ('flagship',   '旗舰版', 5, 10, 1000, NULL, 100, true,  true,  true);

ALTER TABLE public.membership_plans ENABLE ROW LEVEL SECURITY;

CREATE POLICY membership_plans_public_read ON public.membership_plans
  FOR SELECT
  USING (is_active = true);

REVOKE ALL ON public.membership_plans FROM anon, authenticated;
GRANT SELECT ON public.membership_plans TO anon, authenticated;

-- managers 表新增套餐执行字段
ALTER TABLE public.managers
  ADD COLUMN membership_enforcement_mode text NOT NULL DEFAULT 'enforced',
  ADD COLUMN seat_limit_override integer NULL,
  ADD COLUMN client_limit_override integer NULL,
  ADD COLUMN membership_updated_at timestamptz NULL,
  ADD COLUMN membership_updated_by uuid NULL,
  ADD COLUMN membership_note text NULL;

COMMENT ON COLUMN public.managers.membership_enforcement_mode IS 'enforced=按套餐真实拦截；legacy_unlimited=迁移前存量商户保护状态，不限量';
COMMENT ON COLUMN public.managers.seat_limit_override IS '平台为该商户单独设置的坐席数覆盖值，NULL 表示使用套餐默认值';
COMMENT ON COLUMN public.managers.client_limit_override IS '平台为该商户单独设置的客户数覆盖值，NULL 表示使用套餐默认值';

-- 归一化历史脏数据，避免 CHECK 约束报错
UPDATE public.managers
SET membership_level = 'free'
WHERE membership_level IS NULL OR membership_level NOT IN ('free','basic','advanced','enterprise','flagship');

ALTER TABLE public.managers ALTER COLUMN membership_level SET DEFAULT 'free';

DO $$ BEGIN
  ALTER TABLE public.managers
    ADD CONSTRAINT managers_membership_level_check
    CHECK (membership_level IN ('free','basic','advanced','enterprise','flagship'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.managers
    ADD CONSTRAINT managers_membership_enforcement_mode_check
    CHECK (membership_enforcement_mode IN ('enforced','legacy_unlimited'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 关键迁移安全步骤：所有存量商户（迁移前已存在的行）自动置为不限量保护状态，
-- 新注册商户从此刻起才会以 membership_enforcement_mode 默认值 'enforced' + 'free' 套餐入局。
UPDATE public.managers
SET membership_enforcement_mode = 'legacy_unlimited',
    membership_updated_at = now(),
    membership_note = '迁移前存量商户，系统自动设为不限量保护状态'
WHERE membership_enforcement_mode = 'enforced';
