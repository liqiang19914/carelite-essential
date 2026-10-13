CREATE OR REPLACE FUNCTION public.get_lottery_activity(p_activity_id uuid, p_shop_root uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_act public.lottery_activities;
  v_root uuid;
  v_today_draws bigint := 0;
  v_remaining_daily integer := 0;
BEGIN
  SELECT * INTO v_act FROM public.lottery_activities WHERE id = p_activity_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '活动不存在' USING ERRCODE = '22023';
  END IF;

  v_root := public.get_enterprise_root_manager_id(p_shop_root);
  IF v_root IS DISTINCT FROM v_act.enterprise_root_id THEN
    IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
      RAISE EXCEPTION '活动不存在' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_uid IS NOT NULL THEN
    SELECT COUNT(*) INTO v_today_draws
    FROM public.lottery_draw_records dr
    WHERE dr.activity_id = v_act.id
      AND dr.user_id = v_uid
      AND dr.created_at >= date_trunc('day', now());
  END IF;
  v_remaining_daily := GREATEST(v_act.daily_limit - v_today_draws::integer, 0);

  RETURN jsonb_build_object(
    'id', v_act.id,
    'title', v_act.title,
    'display_type', v_act.display_type,
    'description', v_act.description,
    'start_at', v_act.start_at,
    'end_at', v_act.end_at,
    'daily_limit', v_act.daily_limit,
    'is_active', v_act.is_active,
    'phase', CASE
      WHEN NOT v_act.is_active THEN 'disabled'
      WHEN now() < v_act.start_at THEN 'upcoming'
      WHEN now() > v_act.end_at THEN 'ended'
      ELSE 'open'
    END,
    'remaining_daily', v_remaining_daily,
    'today_draws', v_today_draws,
    'prizes', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', p.name, 'prize_type', p.prize_type,
        'product_id', p.product_id, 'points', p.points,
        'sort_order', p.sort_order,
        'requires_shipping', COALESCE(pr.requires_shipping, true)
      ) ORDER BY p.sort_order), '[]'::jsonb)
      FROM public.lottery_prizes p
      LEFT JOIN public.products pr ON pr.id = p.product_id
      WHERE p.activity_id = v_act.id)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.draw_lottery(p_activity_id uuid, p_idempotency_key uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_act  public.lottery_activities;
  v_prize public.lottery_prizes;
  v_today bigint;
  v_r integer;
  v_acc integer := 0;
  v_won boolean := false;
  v_record public.lottery_draw_records;
  v_points integer := 0;
  v_need_ship boolean := true;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION '缺少请求标识，请重试' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_record FROM public.lottery_draw_records
  WHERE idempotency_key = p_idempotency_key::text;
  IF FOUND THEN
    RETURN jsonb_build_object('repeat', true, 'record', row_to_json(v_record));
  END IF;

  SELECT * INTO v_act FROM public.lottery_activities
  WHERE id = p_activity_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '活动不存在' USING ERRCODE = '22023';
  END IF;
  IF NOT v_act.is_active THEN
    RAISE EXCEPTION '活动已停用' USING ERRCODE = '22023';
  END IF;
  IF now() < v_act.start_at THEN
    RAISE EXCEPTION '活动尚未开始' USING ERRCODE = '22023';
  END IF;
  IF now() > v_act.end_at THEN
    RAISE EXCEPTION '活动已结束' USING ERRCODE = '22023';
  END IF;

  SELECT COUNT(*) INTO v_today
  FROM public.lottery_draw_records dr
  WHERE dr.activity_id = v_act.id
    AND dr.user_id = v_uid
    AND dr.created_at >= date_trunc('day', now());
  IF v_today >= v_act.daily_limit THEN
    RAISE EXCEPTION '今天的抽奖次数已用完' USING ERRCODE = '22023';
  END IF;

  v_r := 1 + floor(random() * 10000)::integer;

  FOR v_prize IN
    SELECT * FROM public.lottery_prizes lp
    WHERE lp.activity_id = v_act.id AND lp.weight_bps > 0
    ORDER BY lp.sort_order, lp.id
  LOOP
    v_acc := v_acc + v_prize.weight_bps;
    IF v_r <= v_acc THEN
      IF v_prize.remaining_stock > 0 THEN
        UPDATE public.lottery_prizes
        SET remaining_stock = remaining_stock - 1
        WHERE id = v_prize.id AND remaining_stock > 0;
        IF FOUND THEN
          v_won := true;
          v_points := v_prize.points;
          SELECT COALESCE(pr.requires_shipping, true) INTO v_need_ship
          FROM public.products pr WHERE pr.id = v_prize.product_id;
        END IF;
      END IF;
      EXIT;
    END IF;
  END LOOP;

  INSERT INTO public.lottery_draw_records (
    activity_id, user_id, prize_id, won, idempotency_key
  ) VALUES (
    v_act.id, v_uid, CASE WHEN v_won THEN v_prize.id ELSE NULL END, v_won, p_idempotency_key::text
  )
  RETURNING * INTO v_record;

  IF v_won AND v_prize.prize_type = 'points' AND v_points > 0 THEN
    PERFORM public._post_points_delta(
      v_uid, v_points, 'lottery', '抽奖中奖',
      'lottery:' || v_record.id::text, 'lottery_draw', v_record.id, v_uid
    );
  END IF;

  RETURN jsonb_build_object(
    'repeat', false,
    'record', row_to_json(v_record),
    'won', v_won,
    'prize', CASE WHEN v_won THEN jsonb_build_object(
      'id', v_prize.id, 'name', v_prize.name, 'prize_type', v_prize.prize_type,
      'product_id', v_prize.product_id, 'points', v_points,
      'requires_shipping', v_need_ship
    ) ELSE NULL END
  );
END;
$function$;