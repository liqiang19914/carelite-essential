DROP FUNCTION IF EXISTS public.get_manager_membership_entitlements(uuid);

CREATE FUNCTION public.get_manager_membership_entitlements(p_manager_id uuid)
 RETURNS TABLE(
   root_manager_id uuid,
   plan_code text,
   plan_display_name text,
   enforcement_mode text,
   is_legacy_unlimited boolean,
   hard_enforce_numeric_limits boolean,
   effective_seat_limit integer,
   effective_client_limit integer,
   ai_insight_monthly_limit integer,
   knowledge_doc_limit_per_manager integer,
   enterprise_center_enabled boolean,
   shop_live_enabled boolean,
   current_seat_count integer,
   current_client_count integer,
   current_ai_insight_used integer,
   membership_expires_at timestamptz,
   shop_enabled boolean,
   live_enabled boolean,
   annual_price_cents integer,
   online_purchase_enabled boolean,
   agent_training_enabled boolean,
   oem_branding_enabled boolean,
   custom_model_selection_enabled boolean,
   manager_health_insight_enabled boolean
 )
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_root_id uuid;
  v_caller_root uuid;
  v_root public.managers;
  v_plan public.membership_plans;
  v_is_legacy boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  v_root_id := public.get_membership_root_manager_id(p_manager_id);
  IF v_root_id IS NULL THEN
    RETURN;
  END IF;

  v_caller_root := public.get_membership_root_manager_id(v_caller);

  IF v_caller <> p_manager_id
     AND v_caller_root IS DISTINCT FROM v_root_id
     AND NOT public.is_admin(v_caller) THEN
    RAISE EXCEPTION '无权查看该套餐信息' USING ERRCODE = '42501';
  END IF;

  SELECT m.* INTO v_root FROM public.managers m WHERE m.id = v_root_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT p.* INTO v_plan FROM public.membership_plans p WHERE p.code = v_root.membership_level;
  IF NOT FOUND THEN
    SELECT p.* INTO v_plan FROM public.membership_plans p WHERE p.code = 'free';
  END IF;

  v_is_legacy := (v_root.membership_enforcement_mode = 'legacy_unlimited');

  RETURN QUERY
  SELECT
    v_root_id,
    v_plan.code,
    v_plan.display_name,
    v_root.membership_enforcement_mode,
    v_is_legacy,
    ((NOT v_is_legacy) AND v_plan.hard_enforce_numeric_limits),
    COALESCE(v_root.seat_limit_override, v_plan.manager_seat_limit),
    COALESCE(v_root.client_limit_override, v_plan.client_limit),
    v_plan.ai_insight_monthly_limit,
    v_plan.knowledge_doc_limit_per_manager,
    (v_is_legacy OR v_plan.enterprise_center_enabled),
    (v_is_legacy OR v_plan.shop_live_enabled),
    (
      SELECT COUNT(*)::integer FROM public.profiles emp
      WHERE emp.id = v_root_id
         OR (emp.parent_manager_id = v_root_id AND emp.is_disabled = false AND emp.role = 'manager')
    ),
    (
      SELECT COUNT(DISTINCT cr.client_id)::integer
      FROM public.client_relations cr
      WHERE cr.status = 'active'
        AND (cr.manager_id = v_root_id OR cr.manager_id IN (
          SELECT emp.id FROM public.profiles emp WHERE emp.parent_manager_id = v_root_id
        ))
    ),
    (
      SELECT COUNT(*)::integer FROM public.membership_usage_events ue
      WHERE ue.root_manager_id = v_root_id
        AND ue.metric = 'ai_insight'
        AND ue.period_month = to_char(now(), 'YYYY-MM')
        AND ue.status IN ('reserved','succeeded')
    ),
    v_root.membership_expires_at,
    (v_is_legacy OR v_plan.shop_enabled),
    (v_is_legacy OR v_plan.live_enabled),
    v_plan.annual_price_cents,
    v_plan.online_purchase_enabled,
    (v_is_legacy OR v_plan.agent_training_enabled),
    (v_is_legacy OR v_plan.oem_branding_enabled),
    (v_is_legacy OR v_plan.custom_model_selection_enabled),
    (v_is_legacy OR v_plan.manager_health_insight_enabled);
END;
$function$;
