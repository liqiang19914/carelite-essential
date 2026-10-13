DO $verify$
DECLARE
  v_client uuid;
  v_rel uuid;
  v_history_count int;
  v_manager uuid;
  v_name text;
  v_err text;
  v_state text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"33ebaf48-0877-4754-bd47-ec7c6172affb","role":"authenticated"}', true);
  BEGIN
    PERFORM public.create_manager_client('测试重复', '15652062526', '');
    RAISE EXCEPTION 'VERIFY-FAIL: 重复建档未被拦截';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    IF v_state <> '23505' OR v_err NOT LIKE '%负责%' THEN
      RAISE EXCEPTION 'VERIFY-FAIL: 重复建档提示不符 (%/%)', v_state, v_err;
    END IF;
  END;

  BEGIN
    PERFORM public.transfer_relation_client('b4350a6d-fd77-4fea-89ac-5cf8150de23c', '6d900706-69db-4b9e-a72b-a814a3296ec9', '越权测试');
    RAISE EXCEPTION 'VERIFY-FAIL: 越权转移未被拦截';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    IF v_state <> '42501' THEN
      RAISE EXCEPTION 'VERIFY-FAIL: 越权转移状态码不符(%)', v_state;
    END IF;
  END;

  PERFORM set_config('request.jwt.claims', '{"sub":"33ebaf48-0877-4754-bd47-ec7c6172affb","role":"authenticated"}', true);
  v_client := public.create_manager_client('验证测试客户', '19900000001', '自动化验证');
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'VERIFY-FAIL: 建档失败';
  END IF;

  PERFORM public.rename_relation_client(v_client, '验证改名客户');
  SELECT customer_name INTO v_name
  FROM public.client_relations
  WHERE client_id = v_client
    AND root_manager_id = '6d900706-69db-4b9e-a72b-a814a3296ec9'
    AND status = 'active';
  IF v_name <> '验证改名客户' THEN
    RAISE EXCEPTION 'VERIFY-FAIL: 改名未生效(%)', v_name;
  END IF;

  PERFORM set_config('request.jwt.claims', '{"sub":"6d900706-69db-4b9e-a72b-a814a3296ec9","role":"authenticated"}', true);
  v_rel := public.transfer_relation_client(v_client, 'b8b54711-6c2c-46ea-a057-d8b85408dce8', '验证转移');
  SELECT manager_id INTO v_manager FROM public.client_relations WHERE id = v_rel;
  IF v_manager <> 'b8b54711-6c2c-46ea-a057-d8b85408dce8' THEN
    RAISE EXCEPTION 'VERIFY-FAIL: 转移未生效';
  END IF;

  SELECT count(*) INTO v_history_count
  FROM public.client_assignment_history
  WHERE client_id = v_client;
  IF v_history_count < 2 THEN
    RAISE EXCEPTION 'VERIFY-FAIL: 归属历史不足(%)', v_history_count;
  END IF;

  DELETE FROM public.client_assignment_history WHERE client_id = v_client;
  DELETE FROM public.client_relations WHERE client_id = v_client;
  DELETE FROM public.profiles WHERE id = v_client AND phone = '19900000001';
END
$verify$;