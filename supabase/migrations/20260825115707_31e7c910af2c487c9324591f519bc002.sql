-- 修复 320 遗留：profiles 表没有 display_name 列（一调用即 42703）。
-- 统一口径：manager 推广人取名片名→企业名→昵称，user 取昵称。

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
  v_bound jsonb;
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

  SELECT jsonb_build_object(
    'promoter_id', b.promoter_id,
    'name', COALESCE(NULLIF(m.partner_card_display_name, ''), NULLIF(m.business_name, ''), pr.nickname, ''),
    'short_code', pc.short_code,
    'bound_at', b.bound_at
  ) INTO v_bound
  FROM public.promoter_bindings b
  LEFT JOIN public.profiles pr ON pr.id = b.promoter_id
  LEFT JOIN public.managers m ON m.id = b.promoter_id
  LEFT JOIN public.promotion_codes pc
    ON pc.enterprise_root_id = b.enterprise_root_id AND pc.promoter_id = b.promoter_id
  WHERE b.enterprise_root_id = v_root AND b.client_id = v_uid
  ORDER BY b.bound_at DESC
  LIMIT 1;

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
    'poster_image_url', CASE WHEN v_rule.id IS NULL THEN NULL ELSE v_rule.poster_image_url END,
    'bound_promoter', v_bound,
    'balance_cents', COALESCE(v_acc.balance_cents, 0),
    'reserved_cents', COALESCE(v_acc.reserved_cents, 0),
    'total_earned_cents', COALESCE(v_acc.total_earned_cents, 0)
  );
END;
$function$;

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
  v_total_comm bigint;
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
           COALESCE(NULLIF(m.partner_card_display_name, ''), NULLIF(m.business_name, ''), pr.nickname, '') AS name,
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
    LEFT JOIN public.managers m ON m.id = pc.promoter_id
    WHERE pc.enterprise_root_id = v_root
    ORDER BY pc.created_at DESC
  ) prom;

  SELECT COALESCE(SUM(b.total_commission_cents), 0)
  INTO v_total_comm
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
    'poster_image_url', CASE WHEN v_rule.id IS NULL THEN NULL ELSE v_rule.poster_image_url END,
    'promoters', v_promoters,
    'total_commission_cents', COALESCE(v_total_comm, 0),
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
           COALESCE(NULLIF(m.partner_card_display_name, ''), NULLIF(m.business_name, ''), pr.nickname, '') AS promoter_name,
           COALESCE(pc.nickname, '') AS client_name
    FROM public.promoter_bindings b
    LEFT JOIN public.profiles pr ON pr.id = b.promoter_id
    LEFT JOIN public.managers m ON m.id = b.promoter_id
    LEFT JOIN public.profiles pc ON pc.id = b.client_id
    WHERE b.enterprise_root_id = v_root
    ORDER BY b.bound_at DESC
    LIMIT LEAST(p_limit, 100) OFFSET p_offset
  ) t;

  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
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
           COALESCE(NULLIF(m.partner_card_display_name, ''), NULLIF(m.business_name, ''), p.nickname, '') AS account_name,
           pc.short_code
    FROM public.withdrawal_requests w
    LEFT JOIN public.profiles p ON p.id = w.account_id
    LEFT JOIN public.managers m ON m.id = w.account_id
    LEFT JOIN public.promotion_codes pc ON pc.promoter_id = w.account_id AND pc.enterprise_root_id = w.enterprise_root_id
    WHERE w.enterprise_root_id = v_root
      AND (p_status IS NULL OR w.status = p_status)
    ORDER BY w.created_at DESC
    LIMIT 200
  ) t;

  RETURN v_rows;
END;
$function$;

CREATE OR REPLACE FUNCTION public.list_merchant_lottery_claims(p_activity_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_root uuid := public._my_root_manager_id();
  v_act  public.lottery_activities;
  v_rows jsonb;
BEGIN
  IF v_uid IS NULL OR NOT public.has_enterprise_permission('marketing_center', v_uid) THEN
    RAISE EXCEPTION '没有营销中心权限' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_act FROM public.lottery_activities
  WHERE id = p_activity_id AND enterprise_root_id = v_root;
  IF NOT FOUND THEN
    RAISE EXCEPTION '活动不存在' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT c.id, c.claimed_at, c.prize_type, c.product_id, c.contact_phone,
           c.shipping_name, c.shipping_province, c.shipping_city, c.shipping_district,
           c.shipping_address_detail,
           lp.name AS prize_name,
           COALESCE(p.title, '') AS product_title,
           COALESCE(pr.nickname, '') AS winner_name
    FROM public.lottery_claim_records c
    JOIN public.lottery_draw_records dr ON dr.id = c.draw_record_id
    LEFT JOIN public.lottery_prizes lp ON lp.id = dr.prize_id
    LEFT JOIN public.products p ON p.id = c.product_id
    LEFT JOIN public.profiles pr ON pr.id = dr.user_id
    WHERE dr.activity_id = v_act.id
    ORDER BY c.claimed_at DESC
    LIMIT 500
  ) t;

  RETURN v_rows;
END;
$function$;