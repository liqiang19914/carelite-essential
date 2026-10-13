CREATE OR REPLACE FUNCTION public.admin_update_membership_plan(p_code text, p_patch jsonb)
 RETURNS membership_plans
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid         UUID := auth.uid();
  v_row         membership_plans;
  v_unknown_key TEXT;
  v_allowed     CONSTANT TEXT[] := ARRAY[
    'display_name', 'sort_order',
    'manager_seat_limit', 'client_limit', 'ai_insight_monthly_limit', 'knowledge_doc_limit_per_manager',
    'enterprise_center_enabled', 'shop_live_enabled', 'hard_enforce_numeric_limits', 'is_active',
    'annual_price_cents', 'online_purchase_enabled', 'shop_enabled', 'live_enabled',
    'agent_training_enabled', 'oem_branding_enabled', 'custom_model_selection_enabled', 'manager_health_insight_enabled'
  ];
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden: not authenticated';
  END IF;
  IF NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION 'forbidden: admin role required';
  END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'patch must be a json object';
  END IF;

  SELECT k INTO v_unknown_key
  FROM jsonb_object_keys(p_patch) AS k
  WHERE k <> ALL(v_allowed)
  LIMIT 1;
  IF v_unknown_key IS NOT NULL THEN
    RAISE EXCEPTION 'unknown patch key: %', v_unknown_key;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM membership_plans WHERE code = p_code) THEN
    RAISE EXCEPTION 'membership plan not found: %', p_code;
  END IF;

  UPDATE membership_plans SET
    display_name = CASE WHEN p_patch ? 'display_name' THEN COALESCE(NULLIF(btrim(p_patch->>'display_name'), ''), display_name) ELSE display_name END,
    sort_order = CASE WHEN p_patch ? 'sort_order' THEN COALESCE((p_patch->>'sort_order')::integer, sort_order) ELSE sort_order END,
    manager_seat_limit = CASE WHEN p_patch ? 'manager_seat_limit' THEN COALESCE((p_patch->>'manager_seat_limit')::integer, manager_seat_limit) ELSE manager_seat_limit END,
    client_limit = CASE WHEN p_patch ? 'client_limit' THEN COALESCE((p_patch->>'client_limit')::integer, client_limit) ELSE client_limit END,
    ai_insight_monthly_limit = CASE WHEN p_patch ? 'ai_insight_monthly_limit' THEN (p_patch->>'ai_insight_monthly_limit')::integer ELSE ai_insight_monthly_limit END,
    knowledge_doc_limit_per_manager = CASE WHEN p_patch ? 'knowledge_doc_limit_per_manager' THEN COALESCE((p_patch->>'knowledge_doc_limit_per_manager')::integer, knowledge_doc_limit_per_manager) ELSE knowledge_doc_limit_per_manager END,
    enterprise_center_enabled = CASE WHEN p_patch ? 'enterprise_center_enabled' THEN COALESCE((p_patch->>'enterprise_center_enabled')::boolean, enterprise_center_enabled) ELSE enterprise_center_enabled END,
    shop_live_enabled = CASE WHEN p_patch ? 'shop_live_enabled' THEN COALESCE((p_patch->>'shop_live_enabled')::boolean, shop_live_enabled) ELSE shop_live_enabled END,
    hard_enforce_numeric_limits = CASE WHEN p_patch ? 'hard_enforce_numeric_limits' THEN COALESCE((p_patch->>'hard_enforce_numeric_limits')::boolean, hard_enforce_numeric_limits) ELSE hard_enforce_numeric_limits END,
    is_active = CASE WHEN p_patch ? 'is_active' THEN COALESCE((p_patch->>'is_active')::boolean, is_active) ELSE is_active END,
    annual_price_cents = CASE WHEN p_patch ? 'annual_price_cents' THEN (p_patch->>'annual_price_cents')::integer ELSE annual_price_cents END,
    online_purchase_enabled = CASE WHEN p_patch ? 'online_purchase_enabled' THEN COALESCE((p_patch->>'online_purchase_enabled')::boolean, online_purchase_enabled) ELSE online_purchase_enabled END,
    shop_enabled = CASE WHEN p_patch ? 'shop_enabled' THEN COALESCE((p_patch->>'shop_enabled')::boolean, shop_enabled) ELSE shop_enabled END,
    live_enabled = CASE WHEN p_patch ? 'live_enabled' THEN COALESCE((p_patch->>'live_enabled')::boolean, live_enabled) ELSE live_enabled END,
    agent_training_enabled = CASE WHEN p_patch ? 'agent_training_enabled' THEN COALESCE((p_patch->>'agent_training_enabled')::boolean, agent_training_enabled) ELSE agent_training_enabled END,
    oem_branding_enabled = CASE WHEN p_patch ? 'oem_branding_enabled' THEN COALESCE((p_patch->>'oem_branding_enabled')::boolean, oem_branding_enabled) ELSE oem_branding_enabled END,
    custom_model_selection_enabled = CASE WHEN p_patch ? 'custom_model_selection_enabled' THEN COALESCE((p_patch->>'custom_model_selection_enabled')::boolean, custom_model_selection_enabled) ELSE custom_model_selection_enabled END,
    manager_health_insight_enabled = CASE WHEN p_patch ? 'manager_health_insight_enabled' THEN COALESCE((p_patch->>'manager_health_insight_enabled')::boolean, manager_health_insight_enabled) ELSE manager_health_insight_enabled END,
    updated_at = now()
  WHERE code = p_code
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;
