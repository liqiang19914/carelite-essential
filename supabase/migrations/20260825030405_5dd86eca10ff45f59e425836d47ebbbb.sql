-- ───────────────────────────── 抽奖：商户保存活动 ─────────────────────────────

CREATE OR REPLACE FUNCTION public.save_lottery_activity(
  p_id uuid DEFAULT NULL,
  p_title text DEFAULT '',
  p_display_type text DEFAULT 'wheel',
  p_description text DEFAULT '',
  p_start_at timestamptz DEFAULT NULL,
  p_end_at timestamptz DEFAULT NULL,
  p_daily_limit integer DEFAULT 1,
  p_is_active boolean DEFAULT true,
  p_prizes jsonb DEFAULT '[]'::jsonb
)
RETURNS public.lottery_activities
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_root uuid := public._my_root_manager_id();
  v_act  public.lottery_activities;
  v_prize jsonb;
  v_prize_id uuid;
  v_prize_name text;
  v_prize_type text;
  v_product_id uuid;
  v_points integer;
  v_weight integer;
  v_total_stock integer;
  v_sort integer;
  v_weight_sum bigint := 0;
  v_old_total integer;
  v_won_count bigint;
  v_remaining integer;
  v_kept uuid[] := '{}';
  v_owner_root uuid;
BEGIN
  IF v_uid IS NULL OR NOT public.has_enterprise_permission('marketing_center', v_uid) THEN
    RAISE EXCEPTION '没有营销中心权限' USING ERRCODE = '42501';
  END IF;
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  IF btrim(COALESCE(p_title, '')) = '' THEN
    RAISE EXCEPTION '活动名称不能为空' USING ERRCODE = '22023';
  END IF;
  IF p_display_type NOT IN ('wheel', 'grid') THEN
    RAISE EXCEPTION '活动形态无效' USING ERRCODE = '22023';
  END IF;
  IF p_start_at IS NULL OR p_end_at IS NULL OR p_end_at <= p_start_at THEN
    RAISE EXCEPTION '活动时间无效' USING ERRCODE = '22023';
  END IF;

  FOR v_prize IN SELECT * FROM jsonb_array_elements(COALESCE(p_prizes, '[]'::jsonb)) LOOP
    v_prize_name := btrim(COALESCE(v_prize->>'name', ''));
    v_prize_type := COALESCE(v_prize->>'prize_type', '');
    v_weight := COALESCE((v_prize->>'weight_bps')::integer, 0);
    v_total_stock := COALESCE((v_prize->>'total_stock')::integer, 0);
    IF v_prize_name = '' THEN
      RAISE EXCEPTION '奖品名称不能为空' USING ERRCODE = '22023';
    END IF;
    IF v_prize_type NOT IN ('points', 'product') THEN
      RAISE EXCEPTION '奖品类型无效' USING ERRCODE = '22023';
    END IF;
    IF v_weight < 0 OR v_weight > 10000 THEN
      RAISE EXCEPTION '奖品权重无效' USING ERRCODE = '22023';
    END IF;
    IF v_total_stock < 0 THEN
      RAISE EXCEPTION '奖品库存无效' USING ERRCODE = '22023';
    END IF;
    v_weight_sum := v_weight_sum + v_weight;
    IF v_prize_type = 'points' THEN
      IF COALESCE((v_prize->>'points')::integer, 0) <= 0 THEN
        RAISE EXCEPTION '积分奖品必须填写积分数' USING ERRCODE = '22023';
      END IF;
    ELSE
      v_product_id := (v_prize->>'product_id')::uuid;
      IF v_product_id IS NULL THEN
        RAISE EXCEPTION '商品奖品必须选择商品' USING ERRCODE = '22023';
      END IF;
      SELECT public.get_enterprise_root_manager_id(p.owner_manager_id) INTO v_owner_root
      FROM public.products p WHERE p.id = v_product_id;
      IF v_owner_root IS DISTINCT FROM v_root THEN
        RAISE EXCEPTION '只能选择本店商品作为奖品' USING ERRCODE = '22023';
      END IF;
    END IF;
  END LOOP;

  IF v_weight_sum > 10000 THEN
    RAISE EXCEPTION '全部奖品权重之和不能超过 10000（超出部分视为不中奖）' USING ERRCODE = '22023';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.lottery_activities (
      enterprise_root_id, title, display_type, description,
      start_at, end_at, daily_limit, is_active
    ) VALUES (
      v_root, btrim(p_title), p_display_type, COALESCE(p_description, ''),
      p_start_at, p_end_at, COALESCE(p_daily_limit, 1), COALESCE(p_is_active, true)
    )
    RETURNING * INTO v_act;
  ELSE
    SELECT * INTO v_act FROM public.lottery_activities
    WHERE id = p_id AND enterprise_root_id = v_root
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION '活动不存在' USING ERRCODE = '22023';
    END IF;

    UPDATE public.lottery_activities
    SET title = btrim(p_title),
        display_type = p_display_type,
        description = COALESCE(p_description, ''),
        start_at = p_start_at,
        end_at = p_end_at,
        daily_limit = COALESCE(p_daily_limit, 1),
        is_active = COALESCE(p_is_active, true),
        updated_at = now()
    WHERE id = v_act.id
    RETURNING * INTO v_act;
  END IF;

  -- 奖品替换：带 id 的更新、无 id 的新增、有中奖记录的不得删除
  FOR v_prize IN SELECT * FROM jsonb_array_elements(COALESCE(p_prizes, '[]'::jsonb)) LOOP
    v_prize_id := (v_prize->>'id')::uuid;
    v_prize_name := btrim(COALESCE(v_prize->>'name', ''));
    v_prize_type := COALESCE(v_prize->>'prize_type', '');
    v_points := COALESCE((v_prize->>'points')::integer, 0);
    v_weight := COALESCE((v_prize->>'weight_bps')::integer, 0);
    v_total_stock := COALESCE((v_prize->>'total_stock')::integer, 0);
    v_sort := COALESCE((v_prize->>'sort_order')::integer, 0);
    v_product_id := NULL;
    IF v_prize_type = 'product' THEN
      v_product_id := (v_prize->>'product_id')::uuid;
    END IF;

    IF v_prize_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.lottery_prizes lp
      WHERE lp.id = v_prize_id AND lp.activity_id = v_act.id
    ) THEN
      SELECT COUNT(*) INTO v_won_count
      FROM public.lottery_draw_records dr
      WHERE dr.prize_id = v_prize_id;
      v_remaining := GREATEST(v_total_stock - v_won_count::integer, 0);

      UPDATE public.lottery_prizes
      SET name = v_prize_name,
          prize_type = v_prize_type,
          product_id = v_product_id,
          points = v_points,
          weight_bps = v_weight,
          total_stock = v_total_stock,
          remaining_stock = v_remaining,
          sort_order = v_sort
      WHERE id = v_prize_id AND activity_id = v_act.id;
      v_kept := v_kept || v_prize_id;
    ELSE
      INSERT INTO public.lottery_prizes (
        activity_id, name, prize_type, product_id, points,
        weight_bps, total_stock, remaining_stock, sort_order
      ) VALUES (
        v_act.id, v_prize_name, v_prize_type, v_product_id, v_points,
        v_weight, v_total_stock, v_total_stock, v_sort
      );
    END IF;
  END LOOP;

  -- 删除未保留的奖品；已被抽中的奖品拒绝删除
  FOR v_prize_id IN
    SELECT lp.id FROM public.lottery_prizes lp
    WHERE lp.activity_id = v_act.id AND NOT (lp.id = ANY (v_kept))
  LOOP
    SELECT COUNT(*) INTO v_won_count
    FROM public.lottery_draw_records dr WHERE dr.prize_id = v_prize_id;
    IF COALESCE(v_won_count, 0) > 0 THEN
      RAISE EXCEPTION '有奖品已被抽中，不能删除，可以调高库存保留' USING ERRCODE = '22023';
    END IF;
    DELETE FROM public.lottery_prizes WHERE id = v_prize_id;
  END LOOP;

  RETURN v_act;
END;
$function$;

-- ───────────────────────────── 抽奖：商户活动列表 ─────────────────────────────

CREATE OR REPLACE FUNCTION public.list_merchant_lottery_activities()
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
  IF v_uid IS NULL OR NOT public.has_enterprise_permission('marketing_center', v_uid) THEN
    RAISE EXCEPTION '没有营销中心权限' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT a.id, a.title, a.display_type, a.description, a.start_at, a.end_at,
           a.daily_limit, a.is_active, a.created_at,
           (SELECT COUNT(*) FROM public.lottery_draw_records dr
             WHERE dr.activity_id = a.id) AS draw_count,
           (SELECT COALESCE(jsonb_agg(jsonb_build_object(
              'id', p.id, 'name', p.name, 'prize_type', p.prize_type,
              'product_id', p.product_id, 'points', p.points,
              'weight_bps', p.weight_bps, 'total_stock', p.total_stock,
              'remaining_stock', p.remaining_stock, 'sort_order', p.sort_order
            ) ORDER BY p.sort_order), '[]'::jsonb)
            FROM public.lottery_prizes p WHERE p.activity_id = a.id) AS prizes
    FROM public.lottery_activities a
    WHERE a.enterprise_root_id = v_root
    ORDER BY a.created_at DESC
    LIMIT 100
  ) t;

  RETURN v_rows;
END;
$function$;

-- ───────────────────────────── 抽奖：用户端读取活动 ─────────────────────────────

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

  -- 店上下文校验：活动属于该店企业根；未带店上下文时仅平台管理员可看
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
        'sort_order', p.sort_order
      ) ORDER BY p.sort_order), '[]'::jsonb)
      FROM public.lottery_prizes p
      WHERE p.activity_id = v_act.id)
  );
END;
$function$;

-- ───────────────────────────── 抽奖：服务端抽奖 ─────────────────────────────

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
  v_total_weight integer := 0;
  v_won boolean := false;
  v_record public.lottery_draw_records;
  v_points integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION '缺少请求标识，请重试' USING ERRCODE = '22023';
  END IF;

  -- 幂等：重复请求返回原记录
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

  -- 1..10000 安全随机，落在奖品权重区间即中奖，剩余区间为不中奖
  v_r := 1 + floor(random() * 10000)::integer;

  FOR v_prize IN
    SELECT * FROM public.lottery_prizes lp
    WHERE lp.activity_id = v_act.id AND lp.weight_bps > 0
    ORDER BY lp.sort_order, lp.id
  LOOP
    v_acc := v_acc + v_prize.weight_bps;
    IF v_r <= v_acc THEN
      -- 原子扣库存：并发抢光时此处 0 行更新 → 视作未中奖
      IF v_prize.remaining_stock > 0 THEN
        UPDATE public.lottery_prizes
        SET remaining_stock = remaining_stock - 1
        WHERE id = v_prize.id AND remaining_stock > 0;
        IF FOUND THEN
          v_won := true;
          v_points := v_prize.points;
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

  -- 积分奖同事务发放（幂等键防重复）
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
      'product_id', v_prize.product_id, 'points', v_points
    ) ELSE NULL END
  );
END;
$function$;

-- ───────────────────────────── 抽奖：中奖领取 ─────────────────────────────

CREATE OR REPLACE FUNCTION public.submit_lottery_claim(
  p_draw_record_id uuid,
  p_contact_phone text DEFAULT '',
  p_shipping_name text DEFAULT '',
  p_shipping_province text DEFAULT '',
  p_shipping_city text DEFAULT '',
  p_shipping_district text DEFAULT '',
  p_shipping_address_detail text DEFAULT ''
)
RETURNS public.lottery_claim_records
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_record public.lottery_draw_records;
  v_prize public.lottery_prizes;
  v_claim public.lottery_claim_records;
  v_phone text;
  v_name text;
  v_need_ship boolean := true;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_record FROM public.lottery_draw_records
  WHERE id = p_draw_record_id AND user_id = v_uid
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '中奖记录不存在' USING ERRCODE = '22023';
  END IF;
  IF NOT v_record.won OR v_record.prize_id IS NULL THEN
    RAISE EXCEPTION '该记录没有中奖' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_claim FROM public.lottery_claim_records
  WHERE draw_record_id = v_record.id;
  IF FOUND THEN
    RETURN v_claim;
  END IF;

  SELECT * INTO v_prize FROM public.lottery_prizes WHERE id = v_record.prize_id;
  IF NOT FOUND OR v_prize.prize_type <> 'product' THEN
    RAISE EXCEPTION '积分奖品无需领取' USING ERRCODE = '22023';
  END IF;

  v_phone := btrim(COALESCE(p_contact_phone, ''));
  IF v_phone !~ '^1[3-9][0-9]{9}$' THEN
    RAISE EXCEPTION '请填写正确的手机号' USING ERRCODE = '22023';
  END IF;

  IF v_prize.product_id IS NOT NULL THEN
    SELECT COALESCE(p.requires_shipping, true) INTO v_need_ship
    FROM public.products p WHERE p.id = v_prize.product_id;
  END IF;

  v_name := btrim(COALESCE(p_shipping_name, ''));
  IF v_need_ship THEN
    IF v_name = '' THEN
      RAISE EXCEPTION '请填写收货人' USING ERRCODE = '22023';
    END IF;
    IF btrim(COALESCE(p_shipping_province, '')) = '' OR btrim(COALESCE(p_shipping_city, '')) = ''
       OR btrim(COALESCE(p_shipping_district, '')) = '' OR btrim(COALESCE(p_shipping_address_detail, '')) = '' THEN
      RAISE EXCEPTION '请填写完整收货地址' USING ERRCODE = '22023';
    END IF;
  END IF;

  INSERT INTO public.lottery_claim_records (
    draw_record_id, prize_type, product_id,
    contact_phone, shipping_name, shipping_province, shipping_city,
    shipping_district, shipping_address_detail
  ) VALUES (
    v_record.id, 'product', v_prize.product_id,
    v_phone, v_name, COALESCE(p_shipping_province, ''), COALESCE(p_shipping_city, ''),
    COALESCE(p_shipping_district, ''), COALESCE(p_shipping_address_detail, '')
  )
  RETURNING * INTO v_claim;

  RETURN v_claim;
END;
$function$;

-- ───────────────────────────── 抽奖：商户查看领取记录 ─────────────────────────────

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
           COALESCE(pr.display_name, '') AS winner_name
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

-- ───────────────────────────── 营销中心模块开关：三个函数白名单扩展 ─────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_set_merchant_module_grant(p_manager_id uuid, p_module_key text, p_granted boolean, p_notes text DEFAULT NULL::text)
RETURNS merchant_module_grants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.merchant_module_grants;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '只有平台管理员可以调整商户模块授权' USING ERRCODE = '42501';
  END IF;
  IF p_module_key NOT IN ('shop_order_lifecycle', 'points_exchange', 'view_health_records', 'view_health_insights', 'view_conversations', 'stores', 'native_login', 'marketing_center') THEN
    RAISE EXCEPTION '未知的模块' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.managers WHERE id = p_manager_id) THEN
    RAISE EXCEPTION '找不到该商户' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.merchant_module_grants (
    manager_id, module_key, grant_status, is_enabled, granted_by, notes
  ) VALUES (
    p_manager_id, p_module_key,
    CASE WHEN COALESCE(p_granted, false) THEN 'granted' ELSE 'revoked' END,
    false, v_uid, p_notes
  )
  ON CONFLICT (manager_id, module_key) DO UPDATE
  SET grant_status = CASE WHEN COALESCE(p_granted, false) THEN 'granted' ELSE 'revoked' END,
      is_enabled   = CASE WHEN COALESCE(p_granted, false)
                          THEN public.merchant_module_grants.is_enabled
                          ELSE false END,
      granted_by   = v_uid,
      granted_at   = now(),
      notes        = COALESCE(p_notes, public.merchant_module_grants.notes),
      updated_at   = now()
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_my_merchant_module_state(p_module_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root      uuid;
  v_granted   boolean := false;
  v_enabled   boolean := false;
  v_permitted boolean := true;
  v_is_data   boolean;
BEGIN
  IF p_module_key IS NULL
     OR p_module_key NOT IN ('points_exchange', 'stores', 'shop_order_lifecycle', 'view_health_records', 'view_health_insights', 'view_conversations', 'marketing_center') THEN
    RAISE EXCEPTION '未知的商城模块' USING ERRCODE = '22023';
  END IF;

  v_root := public._my_root_manager_id();
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  SELECT (g.grant_status = 'granted'), COALESCE(g.is_enabled, false)
  INTO v_granted, v_enabled
  FROM public.merchant_module_grants g
  WHERE g.manager_id = v_root
    AND g.module_key = p_module_key;

  v_granted := COALESCE(v_granted, false);
  v_enabled := COALESCE(v_enabled, false);
  v_is_data := p_module_key IN ('view_health_records', 'view_health_insights', 'view_conversations');

  IF v_is_data THEN
    v_permitted := public.has_enterprise_permission(
      CASE p_module_key
        WHEN 'view_health_records'  THEN 'view_health_records'
        WHEN 'view_health_insights' THEN 'health_insights'
        ELSE 'conversations'
      END,
      auth.uid()
    );
  END IF;

  RETURN jsonb_build_object(
    'granted', v_granted,
    'enabled', v_enabled,
    'permitted', COALESCE(v_permitted, false),
    'open', CASE
              WHEN v_is_data THEN v_granted AND COALESCE(v_permitted, false)
              ELSE v_granted AND v_enabled
            END
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_my_merchant_module_enabled(p_module_key text, p_enabled boolean)
RETURNS merchant_module_grants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root uuid := public._my_root_manager_id();
  v_row  public.merchant_module_grants;
  v_parent uuid;
  v_sub_role text;
  v_disabled boolean;
BEGIN
  IF v_root IS NULL THEN
    RAISE EXCEPTION '只有商户账号可以设置商城模块' USING ERRCODE = '42501';
  END IF;
  IF p_module_key IN ('view_health_records', 'view_health_insights', 'view_conversations') THEN
    RAISE EXCEPTION '客户数据的查看权限已改为按角色授予，请到「企业中心 → 角色权限」里为对应角色勾选' USING ERRCODE = '22023';
  END IF;
  IF p_module_key NOT IN ('shop_order_lifecycle', 'points_exchange', 'stores', 'marketing_center') THEN
    RAISE EXCEPTION '未知的模块' USING ERRCODE = '22023';
  END IF;

  SELECT parent_manager_id, sub_role, COALESCE(is_disabled, false)
    INTO v_parent, v_sub_role, v_disabled
    FROM public.profiles
   WHERE id = auth.uid();
  IF v_disabled OR NOT (v_parent IS NULL OR v_sub_role = 'admin') THEN
    RAISE EXCEPTION '只有企业主或企业管理员可以设置商城模块' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_module_grants
  WHERE manager_id = v_root AND module_key = p_module_key
  FOR UPDATE;

  IF v_row.id IS NULL OR v_row.grant_status <> 'granted' THEN
    RAISE EXCEPTION '平台尚未为你开放该模块，请联系平台运营' USING ERRCODE = '42501';
  END IF;

  UPDATE public.merchant_module_grants
  SET is_enabled = COALESCE(p_enabled, false), updated_at = now()
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_storefront_module_state(p_shop_root uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root   uuid;
  v_points boolean := false;
  v_marketing boolean := false;
BEGIN
  -- 平台主店：平台自营积分商品不依赖商户授权，专区常开；营销模块平台主店暂不开放
  IF p_shop_root IS NULL THEN
    RETURN jsonb_build_object('pointsExchange', true, 'marketingCenter', false);
  END IF;

  v_root := public.get_enterprise_root_manager_id(p_shop_root);
  IF v_root IS NOT NULL AND public.is_public_enterprise_content_root(v_root) THEN
    v_points := EXISTS (
      SELECT 1 FROM public.merchant_module_grants g
      WHERE g.manager_id = v_root
        AND g.module_key = 'points_exchange'
        AND g.grant_status = 'granted'
        AND g.is_enabled = TRUE
    );
    v_marketing := EXISTS (
      SELECT 1 FROM public.merchant_module_grants g
      WHERE g.manager_id = v_root
        AND g.module_key = 'marketing_center'
        AND g.grant_status = 'granted'
        AND g.is_enabled = TRUE
    );
  END IF;
  RETURN jsonb_build_object('pointsExchange', v_points, 'marketingCenter', v_marketing);
END;
$function$;