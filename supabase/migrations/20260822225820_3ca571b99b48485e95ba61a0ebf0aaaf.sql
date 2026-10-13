DO $verify$
DECLARE
  v_phone text;
  v_customer_name text;
  v_cnt int := 0;
BEGIN
  -- 员工视角：手机号必须脱敏或为空
  PERFORM set_config('request.jwt.claims', '{"sub":"33ebaf48-0877-4754-bd47-ec7c6172affb","role":"authenticated"}', true);
  SELECT c.phone, c.customer_name INTO v_phone, v_customer_name
  FROM public.get_manager_clients('33ebaf48-0877-4754-bd47-ec7c6172affb') c
  WHERE c.phone IS NOT NULL
  LIMIT 1;
  IF v_phone IS NOT NULL AND v_phone !~ '^1[0-9]{2}\*{4}[0-9]{4}$' THEN
    RAISE EXCEPTION 'VERIFY-FAIL: 员工视角手机号未脱敏(%)', v_phone;
  END IF;

  -- 企业管理员视角：客户名与手机号字段都应有值（超管明文）
  PERFORM set_config('request.jwt.claims', '{"sub":"6d900706-69db-4b9e-a72b-a814a3296ec9","role":"authenticated"}', true);
  SELECT count(*) INTO v_cnt
  FROM public.get_enterprise_clients_with_owner(10, 0, NULL, NULL) c
  WHERE c.customer_name IS NOT NULL AND c.customer_name <> '';
  IF v_cnt < 5 THEN
    RAISE EXCEPTION 'VERIFY-FAIL: 企业客户列表关系名缺失(%)', v_cnt;
  END IF;
END
$verify$;