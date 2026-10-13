-- ============================================================================
-- S3 积分规则商户自定义：商户级覆盖表 + 奖励链路按商户读取（回退平台全局）
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.manager_points_rules (
  root_manager_id       uuid PRIMARY KEY REFERENCES public.managers(id) ON DELETE CASCADE,
  daily_weighing_amount integer,
  daily_login_amount    integer,
  paid_order_amount     integer,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.manager_points_rules ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.manager_points_rules FROM anon, authenticated;

COMMENT ON TABLE public.manager_points_rules IS
  '商户级积分规则覆盖：按企业根商户一行，三列均可为 NULL（NULL = 未覆盖，回退平台全局 system_settings）。读写一律经 SECURITY DEFINER RPC。';
COMMENT ON COLUMN public.manager_points_rules.daily_weighing_amount IS '每日称重奖励积分覆盖值；NULL = 沿用平台全局';
COMMENT ON COLUMN public.manager_points_rules.daily_login_amount IS '每日登录奖励积分覆盖值；NULL = 沿用平台全局';
COMMENT ON COLUMN public.manager_points_rules.paid_order_amount IS '现金订单付款奖励积分覆盖值；NULL = 沿用平台全局';


-- ─── 规则读取：商户覆盖优先，未覆盖回退平台全局 ───
CREATE OR REPLACE FUNCTION public._points_rule_amount_for_merchant(p_key text, p_root_manager_id uuid)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_col integer;
BEGIN
  IF p_root_manager_id IS NOT NULL THEN
    SELECT CASE p_key
      WHEN 'points_daily_weighing_amount' THEN r.daily_weighing_amount
      WHEN 'points_daily_login_amount'    THEN r.daily_login_amount
      WHEN 'points_paid_order_amount'     THEN r.paid_order_amount
      ELSE NULL
    END INTO v_col
    FROM public.manager_points_rules r
    WHERE r.root_manager_id = p_root_manager_id;

    IF v_col IS NOT NULL THEN
      IF v_col < 0 THEN RETURN 0; END IF;
      IF v_col > 100000 THEN RETURN 100000; END IF;
      RETURN v_col;
    END IF;
  END IF;

  RETURN public._points_rule_amount(p_key);
END;
$function$;


-- ─── 输入钳制：负数 → 0，超上限 → 100000，NULL 保持 NULL ───
CREATE OR REPLACE FUNCTION public._clamp_points_rule(p_val integer)
RETURNS integer
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $function$
  SELECT CASE
    WHEN p_val IS NULL THEN NULL
    WHEN p_val < 0 THEN 0
    WHEN p_val > 100000 THEN 100000
    ELSE p_val
  END;
$function$;


-- ─── 每日称重奖励：按测量章（oem_manager_id）解析企业根商户 ───
CREATE OR REPLACE FUNCTION public._award_daily_weighing_points()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid;
  v_amount  integer;
  v_day     date;
BEGIN
  v_amount := public._points_rule_amount_for_merchant(
    'points_daily_weighing_amount',
    public.get_membership_root_manager_id(NEW.oem_manager_id)
  );
  IF v_amount <= 0 THEN
    RETURN NEW;
  END IF;

  SELECT hr.user_id INTO v_user_id
  FROM public.health_records hr
  WHERE hr.id = NEW.record_id;

  IF v_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_day := public._points_business_day(NEW.measured_at);
  IF v_day IS DISTINCT FROM public._points_business_day(now()) THEN
    RETURN NEW;
  END IF;

  PERFORM public._post_points_delta(
    v_user_id,
    v_amount,
    'daily_weighing',
    '每日称重奖励（' || to_char(v_day, 'YYYY-MM-DD') || '）',
    'daily_weighing:' || v_user_id::text || ':' || to_char(v_day, 'YYYYMMDD'),
    'health_record',
    NEW.record_id,
    NULL
  );

  RETURN NEW;
END;
$function$;


-- ─── 每日登录奖励：按用户最近一条 active 商户归属解析根商户 ───
CREATE OR REPLACE FUNCTION public.claim_daily_login_points()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid     uuid := auth.uid();
  v_root    uuid;
  v_amount  integer;
  v_day     date;
  v_key     text;
  v_balance integer;
  v_hit     boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  v_day := public._points_business_day(now());
  v_key := 'daily_login:' || v_uid::text || ':' || to_char(v_day, 'YYYYMMDD');

  SELECT public.get_membership_root_manager_id(cr.manager_id) INTO v_root
  FROM public.client_relations cr
  WHERE cr.client_id = v_uid AND cr.status = 'active'
  ORDER BY cr.created_at DESC
  LIMIT 1;

  v_amount := public._points_rule_amount_for_merchant('points_daily_login_amount', v_root);

  SELECT EXISTS (
    SELECT 1 FROM public.points_ledger l WHERE l.idempotency_key = v_key
  ) INTO v_hit;

  IF v_amount > 0 AND NOT v_hit THEN
    v_balance := public._post_points_delta(
      v_uid, v_amount, 'daily_login',
      '每日登录奖励（' || to_char(v_day, 'YYYY-MM-DD') || '）',
      v_key, NULL, NULL, NULL
    );
    RETURN jsonb_build_object('awarded', true, 'amount', v_amount, 'balance', v_balance);
  END IF;

  SELECT COALESCE(b.balance, 0) INTO v_balance
  FROM public.points_balances b WHERE b.user_id = v_uid;

  RETURN jsonb_build_object('awarded', false, 'amount', 0, 'balance', COALESCE(v_balance, 0));
END;
$function$;


-- ─── 订单付款奖励 + 退款冲正：按订单归属商户解析根商户 ───
CREATE OR REPLACE FUNCTION public._sync_order_points_side_effects()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_old_status text;
  v_amount     integer;
  v_orig_delta integer;
BEGIN
  IF NEW.pay_mode = 'points' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_old_status := NULL;
  ELSE
    v_old_status := OLD.status;
  END IF;

  IF NEW.status = 'paid' AND v_old_status IS DISTINCT FROM 'paid' THEN
    v_amount := public._points_rule_amount_for_merchant(
      'points_paid_order_amount',
      public.get_membership_root_manager_id(NEW.owner_manager_id_snapshot)
    );
    IF v_amount > 0 THEN
      PERFORM public._post_points_delta(
        NEW.user_id, v_amount, 'paid_order',
        '订单支付奖励（单号 ' || COALESCE(NEW.out_trade_no, '-') || '）',
        'paid_order:' || NEW.id::text, 'order', NEW.id, NULL
      );
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status = 'refunded' AND v_old_status IS DISTINCT FROM 'refunded' THEN
    SELECT l.delta INTO v_orig_delta
    FROM public.points_ledger l
    WHERE l.idempotency_key = 'paid_order:' || NEW.id::text;

    IF v_orig_delta IS NOT NULL AND v_orig_delta > 0 THEN
      PERFORM public._post_points_delta(
        NEW.user_id, -v_orig_delta, 'paid_order_reversal',
        '订单退款，收回已发放的支付奖励（单号 ' || COALESCE(NEW.out_trade_no, '-') || '）',
        'paid_order_reversal:' || NEW.id::text, 'order', NEW.id, NULL
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;


-- ─── 用户积分概览：规则按调用者解析（用户 → 最近归属商户；商户 → 自己企业根） ───
CREATE OR REPLACE FUNCTION public.get_my_points_summary()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_bal  public.points_balances;
  v_root uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_bal FROM public.points_balances WHERE user_id = v_uid;

  SELECT public.get_membership_root_manager_id(cr.manager_id) INTO v_root
  FROM public.client_relations cr
  WHERE cr.client_id = v_uid AND cr.status = 'active'
  ORDER BY cr.created_at DESC
  LIMIT 1;

  IF v_root IS NULL THEN
    SELECT CASE WHEN p.parent_manager_id IS NULL THEN p.id ELSE p.parent_manager_id END
      INTO v_root
      FROM public.profiles p
      WHERE p.id = v_uid AND p.role = 'manager';
  END IF;

  RETURN jsonb_build_object(
    'balance',       COALESCE(v_bal.balance, 0),
    'total_earned',  COALESCE(v_bal.total_earned, 0),
    'total_spent',   COALESCE(v_bal.total_spent, 0),
    'rules', jsonb_build_object(
      'daily_weighing', public._points_rule_amount_for_merchant('points_daily_weighing_amount', v_root),
      'daily_login',    public._points_rule_amount_for_merchant('points_daily_login_amount', v_root),
      'paid_order',     public._points_rule_amount_for_merchant('points_paid_order_amount', v_root)
    )
  );
END;
$function$;


-- ─── 商户读取自己的规则覆盖值 + 平台全局默认 ───
CREATE OR REPLACE FUNCTION public.get_my_points_rules()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_root uuid;
  v_row  public.manager_points_rules;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT CASE WHEN p.parent_manager_id IS NULL THEN p.id ELSE p.parent_manager_id END
    INTO v_root
    FROM public.profiles p
    WHERE p.id = v_uid AND p.role = 'manager';

  IF v_root IS NULL THEN
    RAISE EXCEPTION '仅商户可查看积分规则' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row
  FROM public.manager_points_rules r
  WHERE r.root_manager_id = v_root;

  RETURN jsonb_build_object(
    'daily_weighing', v_row.daily_weighing_amount,
    'daily_login',    v_row.daily_login_amount,
    'paid_order',     v_row.paid_order_amount,
    'global', jsonb_build_object(
      'daily_weighing', public._points_rule_amount('points_daily_weighing_amount'),
      'daily_login',    public._points_rule_amount('points_daily_login_amount'),
      'paid_order',     public._points_rule_amount('points_paid_order_amount')
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_my_points_rules() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_points_rules() TO authenticated;


-- ─── 商户保存规则：老板或企业管理员可写；三列全 NULL = 重置回平台默认 ───
CREATE OR REPLACE FUNCTION public.save_my_points_rules(
  p_daily_weighing integer DEFAULT NULL,
  p_daily_login    integer DEFAULT NULL,
  p_paid_order     integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid      uuid := auth.uid();
  v_root     uuid;
  v_is_admin boolean;
  v_w        integer := public._clamp_points_rule(p_daily_weighing);
  v_l        integer := public._clamp_points_rule(p_daily_login);
  v_p        integer := public._clamp_points_rule(p_paid_order);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT (p.parent_manager_id IS NULL OR p.sub_role = 'admin') INTO v_is_admin
  FROM public.profiles p
  WHERE p.id = v_uid AND p.role = 'manager';

  IF v_is_admin IS NOT TRUE THEN
    RAISE EXCEPTION '仅企业管理员可修改积分规则' USING ERRCODE = '42501';
  END IF;

  SELECT CASE WHEN p.parent_manager_id IS NULL THEN p.id ELSE p.parent_manager_id END
    INTO v_root
    FROM public.profiles p
    WHERE p.id = v_uid;

  IF v_w IS NULL AND v_l IS NULL AND v_p IS NULL THEN
    DELETE FROM public.manager_points_rules WHERE root_manager_id = v_root;
  ELSE
    INSERT INTO public.manager_points_rules (
      root_manager_id, daily_weighing_amount, daily_login_amount, paid_order_amount, updated_at
    ) VALUES (v_root, v_w, v_l, v_p, now())
    ON CONFLICT (root_manager_id) DO UPDATE
      SET daily_weighing_amount = EXCLUDED.daily_weighing_amount,
          daily_login_amount    = EXCLUDED.daily_login_amount,
          paid_order_amount     = EXCLUDED.paid_order_amount,
          updated_at            = now();
  END IF;

  RETURN public.get_my_points_rules();
END;
$function$;

REVOKE ALL ON FUNCTION public.save_my_points_rules(integer, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_my_points_rules(integer, integer, integer) TO authenticated;