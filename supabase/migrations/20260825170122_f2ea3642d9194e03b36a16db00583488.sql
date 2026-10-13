-- 积分流水原因白名单补上抽奖：修复前台抽奖中积分奖时报「抽奖失败」的根因
ALTER TABLE public.points_ledger DROP CONSTRAINT pl_reason_code_check;
ALTER TABLE public.points_ledger ADD CONSTRAINT pl_reason_code_check CHECK (
  reason_code = ANY (ARRAY[
    'daily_weighing'::text, 'daily_login'::text, 'paid_order'::text, 'paid_order_reversal'::text,
    'points_redeem'::text, 'points_redeem_refund'::text, 'manual_adjustment'::text, 'lottery'::text
  ])
);