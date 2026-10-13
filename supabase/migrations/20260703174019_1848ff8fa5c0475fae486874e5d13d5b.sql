-- ============================================================
-- get_manager_membership_entitlements：核心权益+用量查询 RPC
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_manager_membership_entitlements(p_manager_id uuid)
RETURNS TABLE (
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
  current_ai_insight_used integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
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
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_manager_membership_entitlements(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_manager_membership_entitlements(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_manager_membership_entitlements(uuid) FROM anon;

-- ============================================================
-- admin_update_manager_membership：平台管理员调整商户套餐
-- ============================================================

CREATE OR REPLACE FUNCTION public.admin_update_manager_membership(
  p_manager_id uuid,
  p_membership_level text,
  p_enforcement_mode text,
  p_seat_limit_override integer,
  p_client_limit_override integer,
  p_note text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅平台管理员可修改套餐' USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.profiles WHERE id = p_manager_id AND parent_manager_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION '该账号为企业员工，套餐继承自企业主，请修改企业主账号' USING ERRCODE = '22023';
  END IF;

  IF p_membership_level NOT IN ('free','basic','advanced','enterprise','flagship') THEN
    RAISE EXCEPTION '无效的套餐档位' USING ERRCODE = '22023';
  END IF;

  IF p_enforcement_mode NOT IN ('enforced','legacy_unlimited') THEN
    RAISE EXCEPTION '无效的执行状态' USING ERRCODE = '22023';
  END IF;

  UPDATE public.managers
  SET membership_level = p_membership_level,
      membership_enforcement_mode = p_enforcement_mode,
      seat_limit_override = p_seat_limit_override,
      client_limit_override = p_client_limit_override,
      membership_note = p_note,
      membership_updated_at = now(),
      membership_updated_by = v_uid
  WHERE id = p_manager_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到该商户' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.operation_logs (user_id, action, detail, module, metadata)
  VALUES (
    v_uid,
    '调整套餐',
    format('将商户 %s 的套餐调整为 %s（执行状态：%s）', p_manager_id::text, p_membership_level, p_enforcement_mode),
    '用户管理',
    jsonb_build_object(
      'manager_id', p_manager_id,
      'membership_level', p_membership_level,
      'enforcement_mode', p_enforcement_mode,
      'seat_limit_override', p_seat_limit_override,
      'client_limit_override', p_client_limit_override
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_update_manager_membership(uuid, text, text, integer, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_manager_membership(uuid, text, text, integer, integer, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_update_manager_membership(uuid, text, text, integer, integer, text) FROM anon;
