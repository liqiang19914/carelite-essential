-- ============ 抽奖失败修复：幂等命中补全结果、并发串行化、积分失败中文回滚 ============

-- 幂等命中/重复请求的结果补全（含奖品明细）
CREATE OR REPLACE FUNCTION public._lottery_repeat_result(p_record public.lottery_draw_records)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_prize jsonb := NULL;
BEGIN
  IF COALESCE(p_record.won, false) AND p_record.prize_id IS NOT NULL THEN
    SELECT jsonb_build_object(
        'id', lp.id, 'name', lp.name, 'prize_type', lp.prize_type,
        'product_id', lp.product_id, 'points', lp.points,
        'requires_shipping', COALESCE(pr.requires_shipping, true)
      ) INTO v_prize
    FROM public.lottery_prizes lp
    LEFT JOIN public.products pr ON pr.id = lp.product_id
    WHERE lp.id = p_record.prize_id;
  END IF;
  RETURN jsonb_build_object(
    'repeat', true,
    'record', row_to_json(p_record),
    'won', COALESCE(p_record.won, false),
    'prize', v_prize
  );
END;
$function$;

REVOKE ALL ON FUNCTION public._lottery_repeat_result(public.lottery_draw_records) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._lottery_repeat_result(public.lottery_draw_records) TO authenticated;
REVOKE EXECUTE ON FUNCTION public._lottery_repeat_result(public.lottery_draw_records) FROM anon;

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

  -- 按用户串行化：同一账号的抽奖请求排队处理，防止并发双抽与日次数竞态
  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text, 11));

  -- 幂等命中：同一请求标识只算一次，返回与首次完全一致的结果
  SELECT * INTO v_record FROM public.lottery_draw_records
  WHERE idempotency_key = p_idempotency_key::text;
  IF FOUND THEN
    IF v_record.user_id <> v_uid THEN
      RAISE EXCEPTION '请求标识无效，请刷新页面后重试' USING ERRCODE = '22023';
    END IF;
    RETURN public._lottery_repeat_result(v_record);
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

  BEGIN
    INSERT INTO public.lottery_draw_records (
      activity_id, user_id, prize_id, won, idempotency_key
    ) VALUES (
      v_act.id, v_uid, CASE WHEN v_won THEN v_prize.id ELSE NULL END, v_won, p_idempotency_key::text
    )
    RETURNING * INTO v_record;
  EXCEPTION
    WHEN unique_violation THEN
      -- 极端并发下同标识双写：以库里已有记录为准
      SELECT * INTO v_record FROM public.lottery_draw_records
      WHERE idempotency_key = p_idempotency_key::text;
      IF NOT FOUND OR v_record.user_id <> v_uid THEN
        RAISE EXCEPTION '请求标识无效，请刷新页面后重试' USING ERRCODE = '22023';
      END IF;
      RETURN public._lottery_repeat_result(v_record);
  END;

  IF v_won AND v_prize.prize_type = 'points' AND v_points > 0 THEN
    BEGIN
      PERFORM public._post_points_delta(
        v_uid, v_points, 'lottery', '抽奖中奖',
        'lottery:' || v_record.id::text, 'lottery_draw', v_record.id, v_uid
      );
    EXCEPTION
      WHEN OTHERS THEN
        -- 积分发不出去时整单回滚（记录与库存一并还原），用户重抽不会重复扣
        RAISE EXCEPTION '积分发放失败，本次抽奖未生效，请稍后重试' USING ERRCODE = 'P0001';
    END;
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

REVOKE ALL ON FUNCTION public.draw_lottery(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.draw_lottery(uuid, uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.draw_lottery(uuid, uuid) FROM anon;