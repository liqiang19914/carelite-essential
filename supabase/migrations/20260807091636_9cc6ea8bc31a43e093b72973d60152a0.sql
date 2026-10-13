-- ============================================================================
-- 商城履约 + 积分体系 批次 1c + 2a：后台默认配置 + 积分记账核心
-- ============================================================================

-- ─────────────────────────────────────────────────────────────
-- 1c) 四个后台可配默认键
--     三条积分规则默认 0 = 不发放，必须由管理员填入真实数值后才生效，
--     避免上线瞬间发生非预期的「积分大放送」。
-- ─────────────────────────────────────────────────────────────
INSERT INTO public.system_settings (key, value, description) VALUES
  ('points_daily_weighing_amount', '0',
   '每日称重可获得的积分数。默认 0 表示不发放，需管理员填写真实数值后才生效。'),
  ('points_daily_login_amount', '0',
   '每天首次登录可获得的积分数。默认 0 表示不发放。'),
  ('points_paid_order_amount', '0',
   '每笔订单支付成功可获得的积分数。默认 0 表示不发放；订单退款时按原奖励金额冲正。'),
  ('shop_auto_receive_days', '7',
   '实体商品发货后自动确认收货的天数。')
ON CONFLICT (key) DO NOTHING;


-- ─────────────────────────────────────────────────────────────
-- 2a-1) 规则读取：配置脏数据一律安全回落为 0，绝不因配置问题中断业务写入
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._points_rule_amount(p_key text)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_raw text;
  v_val integer;
BEGIN
  SELECT s.value INTO v_raw FROM public.system_settings s WHERE s.key = p_key;

  IF v_raw IS NULL OR btrim(v_raw) = '' THEN
    RETURN 0;
  END IF;

  -- 配置是人工输入的边界数据：被写成非数字时回落为「不发放」，
  -- 而不是让称重 / 下单这类主流程因为一个配置格式问题整体失败。
  BEGIN
    v_val := btrim(v_raw)::integer;
  EXCEPTION WHEN others THEN
    RETURN 0;
  END;

  IF v_val IS NULL OR v_val < 0 THEN
    RETURN 0;
  END IF;
  IF v_val > 100000 THEN
    RETURN 100000;  -- 防手滑多打几个零
  END IF;

  RETURN v_val;
END;
$$;

CREATE OR REPLACE FUNCTION public._points_business_day(p_at timestamptz DEFAULT now())
RETURNS date
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT (p_at AT TIME ZONE 'Asia/Shanghai')::date;
$$;

COMMENT ON FUNCTION public._points_business_day(timestamptz) IS
  '积分「每日」的统一业务日边界（东八区）。所有一天一次的规则都必须用它，避免服务器 UTC 日切导致晚上八点后重复领取。';


-- ─────────────────────────────────────────────────────────────
-- 2a-2) 记账核心：余额与流水必须同事务，且按用户行锁串行化
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._post_points_delta(
  p_user_id         uuid,
  p_delta           integer,
  p_reason_code     text,
  p_reason_text     text,
  p_idempotency_key text,
  p_ref_type        text DEFAULT NULL,
  p_ref_id          uuid DEFAULT NULL,
  p_operator_id     uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_balance   integer;
  v_existing  integer;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION '缺少用户，无法记积分' USING ERRCODE = '22023';
  END IF;

  -- 规则配置为 0 时静默跳过：不写流水、不报错，调用方无需自行判断
  IF p_delta IS NULL OR p_delta = 0 THEN
    SELECT b.balance INTO v_balance
    FROM public.points_balances b WHERE b.user_id = p_user_id;
    RETURN COALESCE(v_balance, 0);
  END IF;

  IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
    RAISE EXCEPTION '缺少幂等键，拒绝记积分' USING ERRCODE = '22023';
  END IF;

  -- 先确保余额行存在，再对它加锁。该锁把同一用户的所有积分变动串行化，
  -- 因此下面的「查幂等键 → 算新余额 → 写流水」在锁内是安全的，
  -- 并发的同键调用会在这里排队，第二个进来时已经能看到第一条流水。
  INSERT INTO public.points_balances (user_id) VALUES (p_user_id)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT b.balance INTO v_balance
  FROM public.points_balances b
  WHERE b.user_id = p_user_id
  FOR UPDATE;

  SELECT l.balance_after INTO v_existing
  FROM public.points_ledger l
  WHERE l.idempotency_key = p_idempotency_key;

  IF v_existing IS NOT NULL THEN
    RETURN v_existing;   -- 幂等命中，什么都不改
  END IF;

  v_balance := COALESCE(v_balance, 0) + p_delta;

  UPDATE public.points_balances
  SET balance      = v_balance,
      total_earned = total_earned + GREATEST(p_delta, 0),
      total_spent  = total_spent  + GREATEST(-p_delta, 0),
      updated_at   = now()
  WHERE user_id = p_user_id;

  INSERT INTO public.points_ledger (
    user_id, delta, balance_after, reason_code, reason_text,
    ref_type, ref_id, operator_id, idempotency_key
  ) VALUES (
    p_user_id, p_delta, v_balance, p_reason_code, p_reason_text,
    p_ref_type, p_ref_id, p_operator_id, p_idempotency_key
  );

  RETURN v_balance;
END;
$$;

COMMENT ON FUNCTION public._post_points_delta(uuid,integer,text,text,text,text,uuid,uuid) IS
  '唯一的积分变动入口。持余额行锁 → 查幂等键 → 更新余额 → 追加流水，全部同事务。delta 为 0 时静默跳过。任何业务代码都不得直接写 points_balances / points_ledger。';


-- ─────────────────────────────────────────────────────────────
-- 2a-3) 流水不可变：拒绝一切 UPDATE；DELETE 仅在账号已被删除的级联清理中放行
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._reject_points_ledger_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 账号注销时父行先被删除，此时子行的级联清理必须放行，
  -- 否则删除用户会因为流水表拒绝删除而整体失败。
  IF TG_OP = 'DELETE'
     AND NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = OLD.user_id) THEN
    RETURN OLD;
  END IF;

  RAISE EXCEPTION '积分流水是只增不改的台账，不允许修改或删除' USING ERRCODE = '42501';
END;
$$;

DROP TRIGGER IF EXISTS points_ledger_reject_update ON public.points_ledger;
CREATE TRIGGER points_ledger_reject_update
  BEFORE UPDATE ON public.points_ledger
  FOR EACH ROW EXECUTE FUNCTION public._reject_points_ledger_mutation();

DROP TRIGGER IF EXISTS points_ledger_reject_delete ON public.points_ledger;
CREATE TRIGGER points_ledger_reject_delete
  BEFORE DELETE ON public.points_ledger
  FOR EACH ROW EXECUTE FUNCTION public._reject_points_ledger_mutation();


-- ─────────────────────────────────────────────────────────────
-- 2a-4) 每日称重奖励：挂在体成分表上
--   为什么用触发器而不是改 Edge Function：称重数据有蓝牙上报、设备直连、
--   手动录入三条写入路径，挂在表上才能一次覆盖全部，且不会被将来新增的
--   第四条写入路径绕过。
--   体成分表没有 user_id，只能经 health_records 反查归属人。
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._award_daily_weighing_points()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid;
  v_amount  integer;
  v_day     date;
BEGIN
  v_amount := public._points_rule_amount('points_daily_weighing_amount');
  IF v_amount <= 0 THEN
    RETURN NEW;
  END IF;

  SELECT hr.user_id INTO v_user_id
  FROM public.health_records hr
  WHERE hr.id = NEW.record_id;

  IF v_user_id IS NULL THEN
    RETURN NEW;   -- 档案已不存在，不发分也不阻断称重入库
  END IF;

  -- 只奖励服务器当日的测量。历史补录不发分，否则可以批量补录往期数据刷分。
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
$$;

DROP TRIGGER IF EXISTS body_compositions_award_points ON public.body_compositions;
CREATE TRIGGER body_compositions_award_points
  AFTER INSERT ON public.body_compositions
  FOR EACH ROW EXECUTE FUNCTION public._award_daily_weighing_points();


-- ─────────────────────────────────────────────────────────────
-- 2a-5) 每日登录奖励：由用户端每会话调用一次，幂等
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.claim_daily_login_points()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_amount  integer;
  v_day     date;
  v_key     text;
  v_balance integer;
  v_hit     boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  v_day    := public._points_business_day(now());
  v_key    := 'daily_login:' || v_uid::text || ':' || to_char(v_day, 'YYYYMMDD');
  v_amount := public._points_rule_amount('points_daily_login_amount');

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
$$;

GRANT EXECUTE ON FUNCTION public.claim_daily_login_points() TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 2a-6) 订单付款奖励与退款冲正
--   刻意做成「观察 orders 状态迁移」的触发器，而不是去改
--   mark_order_paid_from_gateway / mark_order_refunded_from_gateway 的函数体，
--   以免触碰刚加固过的支付与退款状态机。
--   冲正金额取原奖励流水的实际值，不取当前配置值：否则管理员改过配置后
--   退款会冲错金额。
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._sync_order_points_side_effects()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_old_status text;
  v_amount     integer;
  v_orig_delta integer;
BEGIN
  IF NEW.pay_mode = 'points' THEN
    RETURN NEW;   -- 积分兑换单本身不再产生积分奖励
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_old_status := NULL;
  ELSE
    v_old_status := OLD.status;
  END IF;

  IF NEW.status = 'paid' AND v_old_status IS DISTINCT FROM 'paid' THEN
    v_amount := public._points_rule_amount('points_paid_order_amount');
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
$$;

DROP TRIGGER IF EXISTS orders_points_side_effects ON public.orders;
CREATE TRIGGER orders_points_side_effects
  AFTER INSERT OR UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public._sync_order_points_side_effects();