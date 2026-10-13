-- ============================================================
-- 联系开通留资 RPC：提交 / 管理员查看 / 管理员更新状态
-- ============================================================

CREATE OR REPLACE FUNCTION public.submit_membership_contact_lead(
  p_desired_plan_code text,
  p_name text,
  p_phone text,
  p_company_name text,
  p_job_title text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF btrim(COALESCE(p_name, '')) = '' THEN
    RAISE EXCEPTION '请填写姓名' USING ERRCODE = '22023';
  END IF;

  IF p_phone IS NULL OR btrim(p_phone) !~ '^[0-9+\-\s]{6,20}$' THEN
    RAISE EXCEPTION '请填写正确的联系电话' USING ERRCODE = '22023';
  END IF;

  IF btrim(COALESCE(p_company_name, '')) = '' THEN
    RAISE EXCEPTION '请填写公司/企业名称' USING ERRCODE = '22023';
  END IF;

  IF p_desired_plan_code IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.membership_plans WHERE code = p_desired_plan_code) THEN
    RAISE EXCEPTION '套餐档位无效' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.membership_contact_leads (
    desired_plan_code, name, phone, company_name, job_title, submitted_by
  ) VALUES (
    p_desired_plan_code,
    btrim(p_name),
    btrim(p_phone),
    btrim(p_company_name),
    NULLIF(btrim(COALESCE(p_job_title, '')), ''),
    auth.uid()
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.submit_membership_contact_lead(text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_membership_contact_lead(text, text, text, text, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_list_membership_contact_leads(
  p_status text DEFAULT NULL,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  desired_plan_code text,
  name text,
  phone text,
  company_name text,
  job_title text,
  status text,
  admin_note text,
  handled_by uuid,
  handled_at timestamptz,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '仅平台管理员可查看' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT l.id, l.desired_plan_code, l.name, l.phone, l.company_name, l.job_title,
         l.status, l.admin_note, l.handled_by, l.handled_at, l.created_at
  FROM public.membership_contact_leads l
  WHERE p_status IS NULL OR l.status = p_status
  ORDER BY l.created_at DESC
  LIMIT LEAST(COALESCE(p_limit, 50), 200)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_membership_contact_leads(text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_membership_contact_leads(text, integer, integer) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_list_membership_contact_leads(text, integer, integer) FROM anon;

CREATE OR REPLACE FUNCTION public.admin_update_membership_contact_lead_status(
  p_lead_id uuid,
  p_status text,
  p_admin_note text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅平台管理员可操作' USING ERRCODE = '42501';
  END IF;

  IF p_status NOT IN ('pending','contacted','activated','closed') THEN
    RAISE EXCEPTION '无效状态' USING ERRCODE = '22023';
  END IF;

  UPDATE public.membership_contact_leads
  SET status = p_status,
      admin_note = COALESCE(p_admin_note, admin_note),
      handled_by = v_uid,
      handled_at = now(),
      updated_at = now()
  WHERE id = p_lead_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到该记录' USING ERRCODE = '22023';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_update_membership_contact_lead_status(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_membership_contact_lead_status(uuid, text, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_update_membership_contact_lead_status(uuid, text, text) FROM anon;

-- ============================================================
-- AI 健康洞察用量：reserve → finalize（succeeded/failed）
-- ============================================================

CREATE OR REPLACE FUNCTION public.reserve_membership_ai_insight_usage(p_actor_manager_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root_id uuid;
  v_root public.managers;
  v_plan public.membership_plans;
  v_period text := to_char(now(), 'YYYY-MM');
  v_current_count integer;
  v_event_id uuid;
BEGIN
  v_root_id := public.get_membership_root_manager_id(p_actor_manager_id);
  IF v_root_id IS NULL THEN
    RAISE EXCEPTION '找不到管理师账号' USING ERRCODE = '22023';
  END IF;

  SELECT m.* INTO v_root FROM public.managers m WHERE m.id = v_root_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到商户账号' USING ERRCODE = '22023';
  END IF;

  IF v_root.membership_enforcement_mode <> 'legacy_unlimited' THEN
    SELECT p.* INTO v_plan FROM public.membership_plans p WHERE p.code = v_root.membership_level;
    IF NOT FOUND THEN
      SELECT p.* INTO v_plan FROM public.membership_plans p WHERE p.code = 'free';
    END IF;

    IF v_plan.ai_insight_monthly_limit IS NOT NULL THEN
      SELECT COUNT(*) INTO v_current_count
      FROM public.membership_usage_events ue
      WHERE ue.root_manager_id = v_root_id
        AND ue.metric = 'ai_insight'
        AND ue.period_month = v_period
        AND ue.status IN ('reserved','succeeded');

      IF v_current_count + 1 > v_plan.ai_insight_monthly_limit AND v_plan.hard_enforce_numeric_limits THEN
        RAISE EXCEPTION 'AI健康洞察本月次数已达套餐上限（%次/月），请联系平台升级套餐', v_plan.ai_insight_monthly_limit
          USING ERRCODE = 'P0001';
      END IF;
    END IF;
  END IF;

  INSERT INTO public.membership_usage_events (root_manager_id, actor_manager_id, metric, period_month, status)
  VALUES (v_root_id, p_actor_manager_id, 'ai_insight', v_period, 'reserved')
  RETURNING id INTO v_event_id;

  RETURN v_event_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.reserve_membership_ai_insight_usage(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reserve_membership_ai_insight_usage(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.reserve_membership_ai_insight_usage(uuid) FROM anon;

CREATE OR REPLACE FUNCTION public.finalize_membership_usage_event(
  p_event_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF p_status NOT IN ('succeeded','failed') THEN
    RAISE EXCEPTION '无效状态' USING ERRCODE = '22023';
  END IF;

  UPDATE public.membership_usage_events
  SET status = p_status, updated_at = now()
  WHERE id = p_event_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.finalize_membership_usage_event(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.finalize_membership_usage_event(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.finalize_membership_usage_event(uuid, text) FROM anon;
