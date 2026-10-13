-- admin_adjust_user_points 增加 applied 返回：Edge Function 用它区分「真实入账」与
-- 「幂等命中」，幂等命中时不重复写审计日志。
-- 幂等判定必须在余额行锁内做才准确：先自行取同一把行锁，再查幂等键；
-- _post_points_delta 随后在同一事务里重取这把锁属于无操作，不引入新的加锁顺序。
CREATE OR REPLACE FUNCTION public.admin_adjust_user_points(
  p_user_id uuid,
  p_delta integer,
  p_reason_text text,
  p_request_id text,
  p_operator_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_reason  text;
  v_key     text;
  v_applied boolean;
  v_balance integer;
BEGIN
  IF p_operator_id IS NULL OR NOT public.is_admin(p_operator_id) THEN
    RAISE EXCEPTION '只有平台管理员可以调整积分' USING ERRCODE = '42501';
  END IF;

  IF p_user_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user_id) THEN
    RAISE EXCEPTION '找不到该用户' USING ERRCODE = '22023';
  END IF;

  IF p_delta IS NULL OR p_delta = 0 THEN
    RAISE EXCEPTION '积分变动值必须是非零整数' USING ERRCODE = '22023';
  END IF;
  IF abs(p_delta) > 1000000 THEN
    RAISE EXCEPTION '单次调整幅度过大，请分次操作' USING ERRCODE = '22023';
  END IF;

  v_reason := btrim(COALESCE(p_reason_text, ''));
  IF v_reason = '' THEN
    RAISE EXCEPTION '必须填写调整原因' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_reason) > 200 THEN
    RAISE EXCEPTION '调整原因最多 200 字' USING ERRCODE = '22023';
  END IF;

  IF p_request_id IS NULL OR btrim(p_request_id) = '' THEN
    RAISE EXCEPTION '缺少请求号，无法保证不重复入账' USING ERRCODE = '22023';
  END IF;

  v_key := 'manual:' || btrim(p_request_id);

  INSERT INTO public.points_balances (user_id) VALUES (p_user_id)
  ON CONFLICT (user_id) DO NOTHING;

  PERFORM 1 FROM public.points_balances
  WHERE user_id = p_user_id
  FOR UPDATE;

  v_applied := NOT EXISTS (
    SELECT 1 FROM public.points_ledger WHERE idempotency_key = v_key
  );

  v_balance := public._post_points_delta(
    p_user_id, p_delta, 'manual_adjustment', v_reason,
    v_key, NULL, NULL, p_operator_id
  );

  RETURN jsonb_build_object(
    'balance', v_balance,
    'delta', p_delta,
    'applied', v_applied
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_adjust_user_points(uuid, integer, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_adjust_user_points(uuid, integer, text, text, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.admin_adjust_user_points(uuid, integer, text, text, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_adjust_user_points(uuid, integer, text, text, uuid) TO service_role;