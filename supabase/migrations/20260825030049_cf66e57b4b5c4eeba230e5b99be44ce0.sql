-- ───────────────────────────── 私有辅助：短码与佣金账本 ─────────────────────────────

CREATE OR REPLACE FUNCTION public._random_short_code()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_chars CONSTANT text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  v_code text := '';
  v_i integer;
BEGIN
  FOR v_i IN 1..4 LOOP
    v_code := v_code || substr(v_chars, 1 + floor(random() * 62)::int, 1);
  END LOOP;
  RETURN v_code;
END;
$function$;

CREATE OR REPLACE FUNCTION public._post_commission_delta(
  p_account_id uuid,
  p_delta_cents integer,
  p_reserved_delta_cents integer,
  p_kind text,
  p_ref_type text,
  p_ref_id uuid,
  p_idempotency_key text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_balance  integer;
  v_reserved integer;
  v_existing integer;
BEGIN
  IF p_account_id IS NULL THEN
    RAISE EXCEPTION '缺少账户，无法记佣金' USING ERRCODE = '22023';
  END IF;
  IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
    RAISE EXCEPTION '缺少幂等键，拒绝记佣金' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.commission_accounts (profile_id) VALUES (p_account_id)
  ON CONFLICT (profile_id) DO NOTHING;

  SELECT c.balance_cents, c.reserved_cents INTO v_balance, v_reserved
  FROM public.commission_accounts c
  WHERE c.profile_id = p_account_id
  FOR UPDATE;

  SELECT l.balance_after_cents INTO v_existing
  FROM public.commission_ledger l
  WHERE l.idempotency_key = p_idempotency_key;

  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  v_balance  := COALESCE(v_balance, 0) + COALESCE(p_delta_cents, 0);
  v_reserved := COALESCE(v_reserved, 0) + COALESCE(p_reserved_delta_cents, 0);

  UPDATE public.commission_accounts
  SET balance_cents = v_balance,
      reserved_cents = v_reserved,
      total_earned_cents = total_earned_cents + GREATEST(COALESCE(p_delta_cents, 0), 0),
      updated_at = now()
  WHERE profile_id = p_account_id;

  INSERT INTO public.commission_ledger (
    account_id, delta_cents, balance_after_cents, kind, ref_type, ref_id, idempotency_key
  ) VALUES (
    p_account_id, COALESCE(p_delta_cents, 0), v_balance, p_kind, p_ref_type, p_ref_id, p_idempotency_key
  );

  RETURN v_balance;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public._random_short_code() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._post_commission_delta(uuid, integer, integer, text, text, uuid, text) FROM PUBLIC, anon, authenticated;

-- ───────────────────────────── 推广人：懒创建我的推广码 ─────────────────────────────

CREATE OR REPLACE FUNCTION public.ensure_my_promotion_code(p_shop_root uuid DEFAULT NULL)
RETURNS public.promotion_codes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_role text;
  v_root uuid;
  v_row  public.promotion_codes;
  v_try  integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT p.role INTO v_role FROM public.profiles p WHERE p.id = v_uid;

  IF v_role = 'manager' THEN
    v_root := public._my_root_manager_id();
  ELSE
    v_root := public.get_enterprise_root_manager_id(p_shop_root);
  END IF;

  IF v_root IS NULL OR NOT public.is_merchant_root(v_root) THEN
    RAISE EXCEPTION '当前门店尚未开通推广' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row FROM public.promotion_codes
  WHERE enterprise_root_id = v_root AND promoter_id = v_uid
  FOR UPDATE;
  IF FOUND THEN
    RETURN v_row;
  END IF;

  LOOP
    v_try := v_try + 1;
    IF v_try > 30 THEN
      RAISE EXCEPTION '推广码生成失败，请重试' USING ERRCODE = '22023';
    END IF;
    BEGIN
      INSERT INTO public.promotion_codes (enterprise_root_id, promoter_id, short_code)
      VALUES (v_root, v_uid, public._random_short_code())
      RETURNING * INTO v_row;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      NULL;
    END;
  END LOOP;

  RETURN v_row;
END;
$function$;

-- ───────────────────────────── 客户扫推广码绑定 ─────────────────────────────

CREATE OR REPLACE FUNCTION public.bind_promoter_by_code(p_short_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid   uuid := auth.uid();
  v_code  public.promotion_codes;
  v_rule  public.promotion_rules;
  v_bind  public.promoter_bindings;
  v_code_raw text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_uid AND role = 'user' AND is_disabled = false) THEN
    RAISE EXCEPTION '只有客户可以绑定推广关系' USING ERRCODE = '42501';
  END IF;

  v_code_raw := btrim(COALESCE(p_short_code, ''));
  IF char_length(v_code_raw) <> 4 THEN
    RAISE EXCEPTION '推广码无效' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_code FROM public.promotion_codes
  WHERE short_code = v_code_raw AND is_active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION '推广码无效或已停用' USING ERRCODE = '22023';
  END IF;
  IF NOT public.is_merchant_root(v_code.enterprise_root_id) THEN
    RAISE EXCEPTION '推广码无效' USING ERRCODE = '22023';
  END IF;
  IF v_code.promoter_id = v_uid THEN
    RAISE EXCEPTION '不能绑定自己的推广码' USING ERRCODE = '22023';
  END IF;

  -- 已绑定：保持首次归属，不改绑，只返回现状
  SELECT * INTO v_bind FROM public.promoter_bindings
  WHERE enterprise_root_id = v_code.enterprise_root_id AND client_id = v_uid
  FOR UPDATE;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'already_bound', true,
      'promoter_id', v_bind.promoter_id,
      'same_promoter', v_bind.promoter_id = v_code.promoter_id,
      'points_granted', false
    );
  END IF;

  SELECT * INTO v_rule FROM public.promotion_rules
  WHERE enterprise_root_id = v_code.enterprise_root_id;

  INSERT INTO public.promoter_bindings (enterprise_root_id, promoter_id, client_id)
  VALUES (v_code.enterprise_root_id, v_code.promoter_id, v_uid)
  RETURNING * INTO v_bind;

  IF v_rule.id IS NOT NULL AND (COALESCE(v_rule.inviter_points, 0) > 0 OR COALESCE(v_rule.invitee_points, 0) > 0) THEN
    IF COALESCE(v_rule.inviter_points, 0) > 0 THEN
      PERFORM public._post_points_delta(
        v_bind.promoter_id, v_rule.inviter_points,
        'promotion', '新客户绑定推广关系奖励',
        'promotion:inviter:' || v_bind.id::text, 'binding', v_bind.id, v_uid
      );
    END IF;
    IF COALESCE(v_rule.invitee_points, 0) > 0 THEN
      PERFORM public._post_points_delta(
        v_uid, v_rule.invitee_points,
        'promotion', '绑定推广关系奖励',
        'promotion:invitee:' || v_bind.id::text, 'binding', v_bind.id, v_uid
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'already_bound', false,
    'promoter_id', v_bind.promoter_id,
    'same_promoter', true,
    'points_granted', true
  );
END;
$function$;

-- ───────────────────────────── 商户保存推广规则 ─────────────────────────────

CREATE OR REPLACE FUNCTION public.save_merchant_promotion_rules(
  p_inviter_points integer,
  p_invitee_points integer,
  p_commission_mode text,
  p_commission_rate_bps integer,
  p_commission_fixed_cents integer
)
RETURNS public.promotion_rules
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root uuid := public._my_root_manager_id();
  v_parent uuid;
  v_sub_role text;
  v_mode text;
  v_rate integer;
  v_fixed integer;
  v_row public.promotion_rules;
BEGIN
  IF v_root IS NULL OR NOT public.is_merchant_root(v_root) THEN
    RAISE EXCEPTION '只有商户账号可以配置推广规则' USING ERRCODE = '42501';
  END IF;

  SELECT parent_manager_id, sub_role INTO v_parent, v_sub_role
  FROM public.profiles WHERE id = auth.uid();
  IF NOT (v_parent IS NULL OR v_sub_role = 'admin') THEN
    RAISE EXCEPTION '只有企业主或企业管理员可以配置推广规则' USING ERRCODE = '42501';
  END IF;

  v_mode := COALESCE(p_commission_mode, 'none');
  IF v_mode NOT IN ('none', 'rate', 'fixed') THEN
    RAISE EXCEPTION '返佣方式无效' USING ERRCODE = '22023';
  END IF;
  v_rate := COALESCE(p_commission_rate_bps, 0);
  v_fixed := COALESCE(p_commission_fixed_cents, 0);
  IF v_rate < 0 OR v_rate > 5000 THEN
    RAISE EXCEPTION '返佣比例无效' USING ERRCODE = '22023';
  END IF;
  IF v_fixed < 0 THEN
    RAISE EXCEPTION '固定返佣金额无效' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.promotion_rules (
    enterprise_root_id, inviter_points, invitee_points,
    commission_mode, commission_rate_bps, commission_fixed_cents
  ) VALUES (
    v_root, COALESCE(p_inviter_points, 0), COALESCE(p_invitee_points, 0),
    v_mode, v_rate, v_fixed
  )
  ON CONFLICT (enterprise_root_id) DO UPDATE
  SET inviter_points = EXCLUDED.inviter_points,
      invitee_points = EXCLUDED.invitee_points,
      commission_mode = EXCLUDED.commission_mode,
      commission_rate_bps = EXCLUDED.commission_rate_bps,
      commission_fixed_cents = EXCLUDED.commission_fixed_cents,
      updated_at = now()
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

-- ───────────────────────────── 我的推广中心（用户/员工视角） ─────────────────────────────

CREATE OR REPLACE FUNCTION public.get_my_promotion_center(p_shop_root uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_role text;
  v_root uuid;
  v_code public.promotion_codes;
  v_rule public.promotion_rules;
  v_acc  public.commission_accounts;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT p.role INTO v_role FROM public.profiles p WHERE p.id = v_uid;
  IF v_role = 'manager' THEN
    v_root := public._my_root_manager_id();
  ELSE
    v_root := public.get_enterprise_root_manager_id(p_shop_root);
  END IF;

  IF v_root IS NULL THEN
    RETURN jsonb_build_object('available', false, 'reason', 'no_enterprise');
  END IF;

  SELECT * INTO v_code FROM public.promotion_codes
  WHERE enterprise_root_id = v_root AND promoter_id = v_uid;
  SELECT * INTO v_rule FROM public.promotion_rules
  WHERE enterprise_root_id = v_root;
  SELECT * INTO v_acc FROM public.commission_accounts
  WHERE profile_id = v_uid;

  RETURN jsonb_build_object(
    'available', true,
    'enterprise_root_id', v_root,
    'code', CASE WHEN v_code.id IS NULL THEN NULL ELSE v_code.short_code END,
    'code_active', CASE WHEN v_code.id IS NULL THEN NULL ELSE v_code.is_active END,
    'rule', CASE WHEN v_rule.id IS NULL THEN NULL ELSE jsonb_build_object(
      'inviter_points', v_rule.inviter_points,
      'invitee_points', v_rule.invitee_points,
      'commission_mode', v_rule.commission_mode,
      'commission_rate_bps', v_rule.commission_rate_bps,
      'commission_fixed_cents', v_rule.commission_fixed_cents
    ) END,
    'balance_cents', COALESCE(v_acc.balance_cents, 0),
    'reserved_cents', COALESCE(v_acc.reserved_cents, 0),
    'total_earned_cents', COALESCE(v_acc.total_earned_cents, 0)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_my_promotion_stats(p_shop_root uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_role text;
  v_root uuid;
  v_bound_count bigint;
  v_order_count bigint;
  v_commission bigint;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT p.role INTO v_role FROM public.profiles p WHERE p.id = v_uid;
  IF v_role = 'manager' THEN
    v_root := public._my_root_manager_id();
  ELSE
    v_root := public.get_enterprise_root_manager_id(p_shop_root);
  END IF;
  IF v_root IS NULL THEN
    RETURN jsonb_build_object('bound_count', 0, 'order_count', 0, 'total_commission_cents', 0);
  END IF;

  SELECT COUNT(*), COALESCE(SUM(b.order_count), 0), COALESCE(SUM(b.total_commission_cents), 0)
  INTO v_bound_count, v_order_count, v_commission
  FROM public.promoter_bindings b
  WHERE b.enterprise_root_id = v_root AND b.promoter_id = v_uid;

  RETURN jsonb_build_object(
    'bound_count', COALESCE(v_bound_count, 0),
    'order_count', COALESCE(v_order_count, 0),
    'total_commission_cents', COALESCE(v_commission, 0)
  );
END;
$function$;

-- ───────────────────────────── 商户后台：推广总览与记录 ─────────────────────────────

CREATE OR REPLACE FUNCTION public.get_merchant_promotion_overview()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_root uuid := public._my_root_manager_id();
  v_rule public.promotion_rules;
  v_promoters jsonb;
  v_stats jsonb;
  v_pending bigint;
BEGIN
  IF v_uid IS NULL OR NOT public.has_enterprise_permission('marketing_center', v_uid) THEN
    RAISE EXCEPTION '没有营销中心权限' USING ERRCODE = '42501';
  END IF;
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_rule FROM public.promotion_rules WHERE enterprise_root_id = v_root;

  SELECT COALESCE(jsonb_agg(prom), '[]'::jsonb) INTO v_promoters
  FROM (
    SELECT pc.promoter_id,
           COALESCE(pr.display_name, '') AS name,
           pr.role,
           pc.short_code,
           pc.is_active,
           pc.created_at,
           (SELECT COUNT(*) FROM public.promoter_bindings b
             WHERE b.enterprise_root_id = pc.enterprise_root_id AND b.promoter_id = pc.promoter_id) AS bound_count,
           (SELECT COALESCE(SUM(b.order_count), 0) FROM public.promoter_bindings b
             WHERE b.enterprise_root_id = pc.enterprise_root_id AND b.promoter_id = pc.promoter_id) AS order_count,
           (SELECT COALESCE(SUM(b.total_commission_cents), 0) FROM public.promoter_bindings b
             WHERE b.enterprise_root_id = pc.enterprise_root_id AND b.promoter_id = pc.promoter_id) AS total_commission_cents,
           (SELECT COALESCE(SUM(c.balance_cents), 0) FROM public.commission_accounts c
             WHERE c.profile_id = pc.promoter_id) AS balance_cents
    FROM public.promotion_codes pc
    LEFT JOIN public.profiles pr ON pr.id = pc.promoter_id
    WHERE pc.enterprise_root_id = v_root
    ORDER BY pc.created_at DESC
  ) prom;

  SELECT COALESCE(SUM(b.total_commission_cents), 0), COALESCE(SUM(b.order_count), 0), COUNT(*)
  INTO v_stats, v_pending, v_pending
  FROM public.promoter_bindings b
  WHERE b.enterprise_root_id = v_root;

  SELECT COUNT(*) INTO v_pending
  FROM public.withdrawal_requests w
  WHERE w.enterprise_root_id = v_root AND w.status = 'pending';

  RETURN jsonb_build_object(
    'rule', CASE WHEN v_rule.id IS NULL THEN NULL ELSE jsonb_build_object(
      'inviter_points', v_rule.inviter_points,
      'invitee_points', v_rule.invitee_points,
      'commission_mode', v_rule.commission_mode,
      'commission_rate_bps', v_rule.commission_rate_bps,
      'commission_fixed_cents', v_rule.commission_fixed_cents
    ) END,
    'promoters', v_promoters,
    'total_commission_cents', COALESCE(v_stats, 0),
    'pending_withdrawal_count', COALESCE(v_pending, 0)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.list_merchant_promotion_bindings(p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_root uuid := public._my_root_manager_id();
  v_total bigint;
  v_rows jsonb;
BEGIN
  IF v_uid IS NULL OR NOT public.has_enterprise_permission('marketing_center', v_uid) THEN
    RAISE EXCEPTION '没有营销中心权限' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total FROM public.promoter_bindings b
  WHERE b.enterprise_root_id = v_root;

  SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT b.id, b.promoter_id, b.client_id, b.order_count, b.total_commission_cents, b.bound_at,
           COALESCE(pr.display_name, '') AS promoter_name,
           COALESCE(pc.display_name, '') AS client_name
    FROM public.promoter_bindings b
    LEFT JOIN public.profiles pr ON pr.id = b.promoter_id
    LEFT JOIN public.profiles pc ON pc.id = b.client_id
    WHERE b.enterprise_root_id = v_root
    ORDER BY b.bound_at DESC
    LIMIT LEAST(p_limit, 100) OFFSET p_offset
  ) t;

  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END;
$function$;

-- ───────────────────────────── 提现：申请 / 我的记录 / 商户审核 ─────────────────────────────

CREATE OR REPLACE FUNCTION public.submit_withdrawal_request(
  p_enterprise_root_id uuid,
  p_amount_cents integer,
  p_idempotency_key uuid
)
RETURNS public.withdrawal_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_acc  public.commission_accounts;
  v_row  public.withdrawal_requests;
  v_amount integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION '缺少请求标识，请重试' USING ERRCODE = '22023';
  END IF;
  v_amount := COALESCE(p_amount_cents, 0);
  IF v_amount < 100 THEN
    RAISE EXCEPTION '单笔提现金额不能低于 1 元' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row FROM public.withdrawal_requests
  WHERE dedupe_key = p_idempotency_key::text;
  IF FOUND THEN
    RETURN v_row;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.promotion_codes pc
    WHERE pc.enterprise_root_id = p_enterprise_root_id AND pc.promoter_id = v_uid
    UNION
    SELECT 1 FROM public.promoter_bindings b
    WHERE b.enterprise_root_id = p_enterprise_root_id AND b.promoter_id = v_uid
    LIMIT 1
  ) THEN
    RAISE EXCEPTION '提现目标无效' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.commission_accounts (profile_id) VALUES (v_uid)
  ON CONFLICT (profile_id) DO NOTHING;

  SELECT * INTO v_acc FROM public.commission_accounts
  WHERE profile_id = v_uid
  FOR UPDATE;

  IF v_acc.balance_cents - v_acc.reserved_cents < v_amount THEN
    RAISE EXCEPTION '可提现余额不足' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.withdrawal_requests (
    account_id, enterprise_root_id, amount_cents, dedupe_key
  ) VALUES (v_uid, p_enterprise_root_id, v_amount, p_idempotency_key::text)
  RETURNING * INTO v_row;

  PERFORM public._post_commission_delta(
    v_uid, -v_amount, v_amount, 'withdrawal_reserve', 'withdrawal', v_row.id,
    'withdrawal:reserve:' || v_row.id::text
  );

  RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_my_withdrawal_requests()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT w.id, w.enterprise_root_id, w.amount_cents, w.status, w.note, w.created_at, w.reviewed_at, w.paid_at
    FROM public.withdrawal_requests w
    WHERE w.account_id = v_uid
    ORDER BY w.created_at DESC
    LIMIT 100
  ) t;

  RETURN v_rows;
END;
$function$;

CREATE OR REPLACE FUNCTION public.list_merchant_withdrawal_requests(p_status text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_root uuid := public._my_root_manager_id();
  v_rows jsonb;
BEGIN
  IF v_uid IS NULL OR NOT public.has_enterprise_permission('marketing_withdrawals', v_uid) THEN
    RAISE EXCEPTION '没有提现审核权限' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT w.id, w.account_id, w.amount_cents, w.status, w.note, w.created_at, w.reviewed_at, w.paid_at,
           COALESCE(p.display_name, '') AS account_name,
           pc.short_code
    FROM public.withdrawal_requests w
    LEFT JOIN public.profiles p ON p.id = w.account_id
    LEFT JOIN public.promotion_codes pc ON pc.promoter_id = w.account_id AND pc.enterprise_root_id = w.enterprise_root_id
    WHERE w.enterprise_root_id = v_root
      AND (p_status IS NULL OR w.status = p_status)
    ORDER BY w.created_at DESC
    LIMIT 200
  ) t;

  RETURN v_rows;
END;
$function$;

CREATE OR REPLACE FUNCTION public.review_merchant_withdrawal(p_request_id uuid, p_approve boolean, p_note text DEFAULT '')
RETURNS public.withdrawal_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_root uuid := public._my_root_manager_id();
  v_row  public.withdrawal_requests;
BEGIN
  IF v_uid IS NULL OR NOT public.has_enterprise_permission('marketing_withdrawals', v_uid) THEN
    RAISE EXCEPTION '没有提现审核权限' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row FROM public.withdrawal_requests
  WHERE id = p_request_id AND enterprise_root_id = v_root
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '提现申请不存在' USING ERRCODE = '22023';
  END IF;
  IF v_row.status <> 'pending' THEN
    RETURN v_row;
  END IF;

  IF COALESCE(p_approve, false) THEN
    UPDATE public.withdrawal_requests
    SET status = 'approved', reviewed_by = v_uid, reviewed_at = now(), note = COALESCE(p_note, '')
    WHERE id = v_row.id
    RETURNING * INTO v_row;
  ELSE
    UPDATE public.withdrawal_requests
    SET status = 'rejected', reviewed_by = v_uid, reviewed_at = now(), note = COALESCE(p_note, '')
    WHERE id = v_row.id
    RETURNING * INTO v_row;

    PERFORM public._post_commission_delta(
      v_row.account_id, v_row.amount_cents, -v_row.amount_cents, 'withdrawal_release',
      'withdrawal', v_row.id, 'withdrawal:release:' || v_row.id::text
    );
  END IF;

  RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION public.mark_merchant_withdrawal_paid(p_request_id uuid)
RETURNS public.withdrawal_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_root uuid := public._my_root_manager_id();
  v_row  public.withdrawal_requests;
BEGIN
  IF v_uid IS NULL OR NOT public.has_enterprise_permission('marketing_withdrawals', v_uid) THEN
    RAISE EXCEPTION '没有提现审核权限' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row FROM public.withdrawal_requests
  WHERE id = p_request_id AND enterprise_root_id = v_root
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '提现申请不存在' USING ERRCODE = '22023';
  END IF;
  IF v_row.status = 'paid' THEN
    RETURN v_row;
  END IF;
  IF v_row.status <> 'approved' THEN
    RAISE EXCEPTION '只有已通过的申请可以标记打款' USING ERRCODE = '22023';
  END IF;

  UPDATE public.withdrawal_requests
  SET status = 'paid', paid_at = now(), reviewed_by = v_uid
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  PERFORM public._post_commission_delta(
    v_row.account_id, 0, -v_row.amount_cents, 'paid_out',
    'withdrawal', v_row.id, 'withdrawal:paid:' || v_row.id::text
  );

  RETURN v_row;
END;
$function$;