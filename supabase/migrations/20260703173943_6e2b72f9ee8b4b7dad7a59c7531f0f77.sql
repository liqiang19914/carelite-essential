-- ============================================================
-- 联系开通留资表 + AI 用量事件表
-- ============================================================

CREATE TABLE public.membership_contact_leads (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  desired_plan_code text NULL REFERENCES public.membership_plans(code),
  name text NOT NULL,
  phone text NOT NULL,
  company_name text NOT NULL,
  job_title text NULL,
  submitted_by uuid NULL,
  status text NOT NULL DEFAULT 'pending',
  admin_note text NULL,
  handled_by uuid NULL,
  handled_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.membership_contact_leads IS '套餐落地页「联系开通」留资表：仅可通过 SECURITY DEFINER RPC 读写，不对 anon/authenticated 开放直接表访问';

DO $$ BEGIN
  ALTER TABLE public.membership_contact_leads
    ADD CONSTRAINT membership_contact_leads_status_check
    CHECK (status IN ('pending','contacted','activated','closed'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE INDEX idx_membership_contact_leads_status_created
  ON public.membership_contact_leads (status, created_at DESC);

ALTER TABLE public.membership_contact_leads ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.membership_contact_leads FROM anon, authenticated;

CREATE TABLE public.membership_usage_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id),
  actor_manager_id uuid NOT NULL,
  metric text NOT NULL,
  period_month text NOT NULL,
  status text NOT NULL DEFAULT 'reserved',
  resource_id uuid NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.membership_usage_events IS 'AI健康洞察等按月计量指标的用量事件日志，reserve→succeeded/failed 三态防并发绕过';

DO $$ BEGIN
  ALTER TABLE public.membership_usage_events
    ADD CONSTRAINT membership_usage_events_status_check
    CHECK (status IN ('reserved','succeeded','failed'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE public.membership_usage_events
    ADD CONSTRAINT membership_usage_events_metric_check
    CHECK (metric IN ('ai_insight'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE INDEX idx_membership_usage_events_root_metric_period
  ON public.membership_usage_events (root_manager_id, metric, period_month)
  WHERE status IN ('reserved','succeeded');

ALTER TABLE public.membership_usage_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.membership_usage_events FROM anon, authenticated;

-- ============================================================
-- 辅助函数：解析企业主 root_manager_id（员工 → boss.id；boss → 自身）
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_membership_root_manager_id(p_manager_id uuid)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT COALESCE(pr.parent_manager_id, pr.id)
  FROM public.profiles pr
  WHERE pr.id = p_manager_id;
$function$;

REVOKE ALL ON FUNCTION public.get_membership_root_manager_id(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_membership_root_manager_id(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_membership_root_manager_id(uuid) FROM anon;
