DO $verify$
DECLARE
  v_payload jsonb;
  v_err text;
  v_state text;
BEGIN
  v_payload := public.get_public_survey('TI8GCHJL');
  IF v_payload IS NULL OR v_payload->>'survey' IS NULL THEN
    RAISE EXCEPTION 'VERIFY-FAIL: 公开问卷载荷缺失';
  END IF;

  BEGIN
    PERFORM public.get_public_survey('ZZZZZZZZ');
    RAISE EXCEPTION 'VERIFY-FAIL: 无效分享码未被拦截';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
    IF v_state <> '22023' OR v_err NOT LIKE '%问卷不存在%' THEN
      RAISE EXCEPTION 'VERIFY-FAIL: 无效分享码错误不符 (%/%)', v_state, v_err;
    END IF;
  END;
END
$verify$;