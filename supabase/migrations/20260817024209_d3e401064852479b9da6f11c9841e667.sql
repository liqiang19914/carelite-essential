DO $fn$
DECLARE
  v_mid uuid;
  v_global_login integer;
  v_w integer;
  v_l integer;
  v_p integer;
BEGIN
  SELECT id INTO v_mid FROM public.managers ORDER BY created_at LIMIT 1;
  IF v_mid IS NULL THEN
    RAISE EXCEPTION 'no manager for test';
  END IF;

  INSERT INTO public.manager_points_rules (root_manager_id, daily_weighing_amount, daily_login_amount, paid_order_amount)
  VALUES (v_mid, 7, 8, 9);

  SELECT public._points_rule_amount_for_merchant('points_daily_weighing_amount', v_mid) INTO v_w;
  SELECT public._points_rule_amount_for_merchant('points_daily_login_amount', v_mid) INTO v_l;
  SELECT public._points_rule_amount_for_merchant('points_paid_order_amount', v_mid) INTO v_p;

  IF v_w <> 7 OR v_l <> 8 OR v_p <> 9 THEN
    RAISE EXCEPTION 'override mismatch: %/%/%', v_w, v_l, v_p;
  END IF;

  UPDATE public.manager_points_rules SET daily_login_amount = NULL WHERE root_manager_id = v_mid;
  SELECT public._points_rule_amount('points_daily_login_amount') INTO v_global_login;
  SELECT public._points_rule_amount_for_merchant('points_daily_login_amount', v_mid) INTO v_l;
  IF v_l <> v_global_login THEN
    RAISE EXCEPTION 'partial fallback mismatch: % vs %', v_l, v_global_login;
  END IF;

  DELETE FROM public.manager_points_rules WHERE root_manager_id = v_mid;
END;
$fn$;