-- ① 海报底图配置列
ALTER TABLE public.promotion_rules ADD COLUMN IF NOT EXISTS poster_image_url text NULL;
ALTER TABLE public.promotion_rules DROP CONSTRAINT IF EXISTS promotion_rules_poster_image_url_check;
ALTER TABLE public.promotion_rules ADD CONSTRAINT promotion_rules_poster_image_url_check
CHECK (poster_image_url IS NULL OR (char_length(poster_image_url) <= 2048 AND poster_image_url ~ '^https://'));

-- ② 商户设置/清除推广海报底图
CREATE OR REPLACE FUNCTION public.set_merchant_promotion_poster(p_poster_image_url text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid := public._my_root_manager_id();
  v_parent uuid;
  v_sub_role text;
  v_url text := NULLIF(btrim(COALESCE(p_poster_image_url, '')), '');
BEGIN
  IF v_uid IS NULL OR NOT public.has_enterprise_permission('marketing_center', v_uid) THEN
    RAISE EXCEPTION '没有营销中心权限' USING ERRCODE = '42501';
  END IF;
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  SELECT parent_manager_id, sub_role INTO v_parent, v_sub_role
  FROM public.profiles WHERE id = v_uid;
  IF NOT (v_parent IS NULL OR v_sub_role = 'admin') THEN
    RAISE EXCEPTION '只有企业主或企业管理员可以设置推广海报' USING ERRCODE = '42501';
  END IF;

  IF v_url IS NOT NULL AND (char_length(v_url) > 2048 OR v_url !~ '^https://') THEN
    RAISE EXCEPTION '海报底图地址无效' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.promotion_rules (enterprise_root_id, poster_image_url)
  VALUES (v_root, v_url)
  ON CONFLICT (enterprise_root_id) DO UPDATE
  SET poster_image_url = EXCLUDED.poster_image_url,
      updated_at = now();

  RETURN v_url;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.set_merchant_promotion_poster(text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.set_merchant_promotion_poster(text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.set_merchant_promotion_poster(text) FROM PUBLIC;

-- ③ 推广码改为 5 位纯数字
CREATE OR REPLACE FUNCTION public._random_short_code()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_code text := '';
  v_i integer;
BEGIN
  FOR v_i IN 1..5 LOOP
    v_code := v_code || (floor(random() * 10)::integer)::text;
  END LOOP;
  RETURN v_code;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public._random_short_code() FROM PUBLIC, anon, authenticated;

-- ④ 我的推广中心：返回海报底图与我绑定的推广人
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
    'name', COALESCE(pr.display_name, ''),
    'short_code', pc.short_code,
    'bound_at', b.bound_at
  ) INTO v_bound
  FROM public.promoter_bindings b
  LEFT JOIN public.profiles pr ON pr.id = b.promoter_id
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

-- ⑤ 商户推广总览：返回海报底图
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

-- ⑥ 企业客户列表：按客户去重（当前归属优先、最新保留），去重先于负责人过滤/计数/分页
CREATE OR REPLACE FUNCTION public.get_enterprise_clients_with_owner(
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0,
  p_search text DEFAULT NULL,
  p_owner_manager_id uuid DEFAULT NULL,
  p_created_from date DEFAULT NULL,
  p_created_to date DEFAULT NULL,
  p_reminder_from date DEFAULT NULL,
  p_reminder_to date DEFAULT NULL
)
RETURNS TABLE(
  relation_id uuid,
  client_id uuid,
  status text,
  notes text,
  last_contact_at timestamptz,
  relation_created_at timestamptz,
  customer_name text,
  nickname text,
  phone text,
  avatar_url text,
  privacy_settings jsonb,
  owner_manager_id uuid,
  owner_manager_nickname text,
  owner_manager_phone text,
  owner_sub_role text,
  owner_is_disabled boolean,
  shop_member_number text,
  shop_first_entered_at timestamptz,
  store_name text,
  next_reminder_at timestamptz,
  reminder_status text,
  total_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_limit int;
  v_offset int;
  v_search text;
  v_today date;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF NOT public.is_enterprise_admin(v_uid) THEN
    RAISE EXCEPTION '仅企业管理员可访问' USING ERRCODE = '42501';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RETURN;
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);
  v_search := NULLIF(TRIM(COALESCE(p_search, '')), '');
  v_today := (now() AT TIME ZONE 'Asia/Shanghai')::date;

  RETURN QUERY
  WITH members AS (
    SELECT v_root AS mid
    UNION
    SELECT p.id
    FROM public.profiles p
    WHERE p.parent_manager_id = v_root AND p.role = 'manager'
  ),
  deduplicated_relations AS (
    SELECT DISTINCT ON (cr.client_id)
      cr.id AS relation_id,
      cr.client_id,
      cr.status::text AS status,
      cr.notes,
      cr.last_contact_at,
      cr.created_at AS relation_created_at,
      cr.manager_id AS owner_manager_id,
      cr.customer_name
    FROM public.client_relations cr
    WHERE cr.manager_id IN (SELECT mid FROM members)
    ORDER BY
      cr.client_id,
      (cr.status = 'active') DESC,
      cr.updated_at DESC NULLS LAST,
      cr.created_at DESC,
      cr.id DESC
  ),
  relation_scoped AS (
    SELECT d.*
    FROM deduplicated_relations d
    WHERE (p_owner_manager_id IS NULL OR d.owner_manager_id = p_owner_manager_id)
      AND (
        v_search IS NULL
        OR EXISTS (
          SELECT 1 FROM public.profiles cp
          WHERE cp.id = d.client_id
            AND (cp.nickname ILIKE '%' || v_search || '%'
                 OR cp.phone ILIKE '%' || v_search || '%')
        )
        OR d.customer_name ILIKE '%' || v_search || '%'
      )
      AND (p_created_from IS NULL OR (d.relation_created_at AT TIME ZONE 'Asia/Shanghai')::date >= p_created_from)
      AND (p_created_to IS NULL OR (d.relation_created_at AT TIME ZONE 'Asia/Shanghai')::date <= p_created_to)
  ),
  with_reminder AS (
    SELECT
      c.*,
      rem.next_reminder_at
    FROM relation_scoped c
    LEFT JOIN LATERAL (
      SELECT fr.next_follow_up_at AS next_reminder_at
      FROM public.follow_up_records fr
      WHERE fr.client_relation_id = c.relation_id
        AND fr.reminder
        AND fr.next_follow_up_at IS NOT NULL
      ORDER BY fr.next_follow_up_at DESC
      LIMIT 1
    ) rem ON true
  ),
  filtered_rows AS (
    SELECT
      c.relation_id,
      c.client_id,
      c.status,
      c.notes,
      c.last_contact_at,
      c.relation_created_at,
      COALESCE(NULLIF(BTRIM(c.customer_name), ''), cp.nickname::text, '未命名客户') AS customer_name,
      cp.nickname::text,
      CASE
        WHEN COALESCE(cp.privacy_settings->>'show_phone', 'true') = 'false' THEN NULL
        WHEN public.is_admin(v_uid) THEN cp.phone::text
        WHEN public.is_enterprise_admin(v_uid) THEN cp.phone::text
        WHEN cp.phone ~ '^1[0-9]{10}$' THEN LEFT(cp.phone, 3) || '****' || RIGHT(cp.phone, 4)
        ELSE NULL
      END AS phone,
      cp.avatar_url,
      COALESCE(cp.privacy_settings, '{}'::jsonb) AS privacy_settings,
      c.owner_manager_id,
      op.nickname::text AS owner_manager_nickname,
      op.phone::text AS owner_manager_phone,
      COALESCE(op.sub_role, '')::text AS owner_sub_role,
      COALESCE(op.is_disabled, false) AS owner_is_disabled,
      sm.member_number AS shop_member_number,
      sm.first_entered_at AS shop_first_entered_at,
      st.name::text AS store_name,
      c.next_reminder_at,
      CASE
        WHEN c.next_reminder_at IS NULL THEN 'none'
        WHEN (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date < v_today THEN 'overdue'
        WHEN (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date = v_today THEN 'today'
        ELSE 'upcoming'
      END AS reminder_status
    FROM with_reminder c
    LEFT JOIN public.profiles cp ON cp.id = c.client_id
    LEFT JOIN public.profiles op ON op.id = c.owner_manager_id
    LEFT JOIN public.shop_members sm
      ON sm.root_manager_id = v_root AND sm.client_id = c.client_id
    LEFT JOIN public.user_store_bindings b
      ON b.user_id = c.client_id AND b.status = 'active'
    LEFT JOIN public.stores st
      ON st.id = b.store_id AND st.root_manager_id = v_root
    WHERE (p_reminder_from IS NULL OR (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date >= p_reminder_from)
      AND (p_reminder_to IS NULL OR (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date <= p_reminder_to)
  ),
  counted_rows AS (
    SELECT f.*, COUNT(*) OVER() AS total_count
    FROM filtered_rows f
  )
  SELECT *
  FROM counted_rows
  ORDER BY relation_created_at DESC, relation_id DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid, date, date, date, date) TO authenticated;

-- ⑦ 员工客户列表：按客户去重
CREATE OR REPLACE FUNCTION public.get_manager_clients(p_manager_id uuid)
RETURNS TABLE(
  relation_id uuid,
  client_id uuid,
  status text,
  notes text,
  last_contact_at timestamptz,
  relation_created_at timestamptz,
  customer_name text,
  nickname text,
  phone text,
  avatar_url text,
  privacy_settings jsonb,
  shop_member_number text,
  shop_first_entered_at timestamptz,
  store_name text,
  next_reminder_at timestamptz,
  reminder_status text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH authorized AS (
    SELECT 1
    WHERE auth.uid() = p_manager_id
       OR is_admin(auth.uid())
       OR is_enterprise_member_for_admin(p_manager_id, auth.uid())
  ),
  root_id AS (
    SELECT public.get_enterprise_root_manager_id(p_manager_id) AS rid
  ),
  deduplicated AS (
    SELECT DISTINCT ON (cr.client_id)
      cr.id AS relation_id,
      cr.client_id,
      cr.status::text,
      cr.notes,
      cr.last_contact_at,
      cr.created_at AS relation_created_at,
      cr.customer_name
    FROM client_relations cr
    WHERE cr.manager_id = p_manager_id
    ORDER BY
      cr.client_id,
      (cr.status = 'active') DESC,
      cr.updated_at DESC NULLS LAST,
      cr.created_at DESC,
      cr.id DESC
  ),
  with_reminder AS (
    SELECT c.*, rem.next_reminder_at
    FROM deduplicated c
    LEFT JOIN LATERAL (
      SELECT fr.next_follow_up_at AS next_reminder_at
      FROM follow_up_records fr
      WHERE fr.client_relation_id = c.relation_id
        AND fr.reminder
        AND fr.next_follow_up_at IS NOT NULL
      ORDER BY fr.next_follow_up_at DESC
      LIMIT 1
    ) rem ON true
  )
  SELECT
    c.relation_id,
    c.client_id,
    c.status,
    c.notes,
    c.last_contact_at,
    c.relation_created_at,
    COALESCE(NULLIF(BTRIM(c.customer_name), ''), p.nickname::text, '未命名客户') AS customer_name,
    p.nickname::text,
    CASE
      WHEN COALESCE(p.privacy_settings->>'show_phone', 'true') = 'false' THEN NULL
      WHEN public.is_admin(auth.uid()) THEN p.phone::text
      WHEN EXISTS (
        SELECT 1 FROM public.profiles caller
        WHERE caller.id = auth.uid()
          AND caller.role = 'manager'
          AND COALESCE(caller.is_disabled, false) = false
          AND (caller.parent_manager_id IS NULL OR caller.sub_role = 'admin')
          AND public.get_enterprise_root_manager_id(caller.id) = (SELECT rid FROM root_id)
      ) THEN p.phone::text
      WHEN p.phone ~ '^1[0-9]{10}$' THEN LEFT(p.phone, 3) || '****' || RIGHT(p.phone, 4)
      ELSE NULL
    END AS phone,
    p.avatar_url,
    COALESCE(p.privacy_settings, '{}'::jsonb) AS privacy_settings,
    sm.member_number AS shop_member_number,
    sm.first_entered_at AS shop_first_entered_at,
    st.name::text AS store_name,
    c.next_reminder_at,
    CASE
      WHEN c.next_reminder_at IS NULL THEN 'none'
      WHEN (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date < ((now() AT TIME ZONE 'Asia/Shanghai')::date) THEN 'overdue'
      WHEN (c.next_reminder_at AT TIME ZONE 'Asia/Shanghai')::date = ((now() AT TIME ZONE 'Asia/Shanghai')::date) THEN 'today'
      ELSE 'upcoming'
    END AS reminder_status
  FROM with_reminder c
  CROSS JOIN authorized
  LEFT JOIN profiles p ON p.id = c.client_id
  LEFT JOIN shop_members sm
    ON sm.root_manager_id = (SELECT rid FROM root_id) AND sm.client_id = c.client_id
  LEFT JOIN user_store_bindings b
    ON b.user_id = c.client_id AND b.status = 'active'
  LEFT JOIN stores st
    ON st.id = b.store_id AND st.root_manager_id = (SELECT rid FROM root_id)
  ORDER BY c.relation_created_at DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.get_manager_clients(uuid) TO authenticated;

-- ⑧ 抽奖：保存活动时保留新插入的奖品
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

  IF BTRIM(COALESCE(p_title, '')) = '' THEN
    RAISE EXCEPTION '活动名称不能为空' USING ERRCODE = '22023';
  END IF;
  IF p_display_type NOT IN ('wheel', 'grid') THEN
    RAISE EXCEPTION '活动形态无效' USING ERRCODE = '22023';
  END IF;
  IF p_start_at IS NULL OR p_end_at IS NULL OR p_end_at <= p_start_at THEN
    RAISE EXCEPTION '活动时间无效' USING ERRCODE = '22023';
  END IF;

  FOR v_prize IN SELECT * FROM jsonb_array_elements(COALESCE(p_prizes, '[]'::jsonb)) LOOP
    v_prize_name := BTRIM(COALESCE(v_prize->>'name', ''));
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
      v_root, BTRIM(p_title), p_display_type, COALESCE(p_description, ''),
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
    SET title = BTRIM(p_title),
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

  FOR v_prize IN SELECT * FROM jsonb_array_elements(COALESCE(p_prizes, '[]'::jsonb)) LOOP
    v_prize_id := (v_prize->>'id')::uuid;
    v_prize_name := BTRIM(COALESCE(v_prize->>'name', ''));
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
      )
      RETURNING id INTO v_prize_id;
      v_kept := ARRAY_APPEND(v_kept, v_prize_id);
    END IF;
  END LOOP;

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