-- ─────────────────────────────────────────────────────────────────────
-- 商户「渠道推广」：投放渠道码 + 漏斗埋点 + 注册归因
--
-- 与文档平台版（platform_channels，p- 前缀、全平台共享）不同，本套是
-- **商户隔离**：每个商户只能看/建自己的渠道，数据按 root_manager_id 过滤。
-- 渠道短码 8 位 base62，全局唯一（不分商户），scene = mc/<短码>（共 11 字符）。
-- ─────────────────────────────────────────────────────────────────────

-- 1. 渠道主表
CREATE TABLE IF NOT EXISTS public.merchant_channels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL,                 -- 商户企业根
  code text NOT NULL,                            -- 8 位 base62 短码，全局唯一
  name text NOT NULL,                            -- 展示名：抖音信息流 / 线下海报 ...
  category text NOT NULL DEFAULT 'other',       -- feed/private/offline/partner/sms/other
  target_page text NOT NULL DEFAULT 'pages/index/index',  -- 小程序落地页
  remark text,
  is_active boolean NOT NULL DEFAULT true,

  -- 物料（由 generate-miniapp-code EF 填充 image_base64，这里只存元信息）
  qr_mime_type text,                             -- image/png | image/jpeg
  qr_generated_at timestamptz,
  qr_app_id text,                                -- 生成时实际使用的小程序 AppID
  -- 自有域名跳转地址无需落库：/go/<code> 实时拼

  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 短码全局唯一（小程序码 scene 不带商户维度，靠短码反查商户）
CREATE UNIQUE INDEX IF NOT EXISTS merchant_channels_code_idx
  ON public.merchant_channels (code);
-- 商户列表页按企业根过滤
CREATE INDEX IF NOT EXISTS merchant_channels_root_idx
  ON public.merchant_channels (root_manager_id, created_at DESC);

-- code 一经创建不可改（印在物料上，改了等于把扫码用户变孤儿）
COMMENT ON TABLE public.merchant_channels IS '商户投放渠道码。code 不可改；删除走软删（is_active=false）';

-- 2. 到访 / 点击事件（无 RLS 写策略，只能由 EF 以 service_role 经 RPC 写入）
CREATE TABLE IF NOT EXISTS public.merchant_channel_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  channel_code text NOT NULL,
  root_manager_id uuid NOT NULL,                 -- 冗余商户根，统计时免 JOIN
  event_type text NOT NULL,                      -- 'scan' | 'click'
  visitor_key text NOT NULL,                     -- 匿名访客标识（cookie / 设备指纹）
  source text NOT NULL DEFAULT 'unknown',        -- qr | link | open_tag | web | share | sms
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS merchant_channel_events_code_time_idx
  ON public.merchant_channel_events (channel_code, event_type, created_at);
CREATE INDEX IF NOT EXISTS merchant_channel_events_visitor_idx
  ON public.merchant_channel_events (visitor_key, channel_code, event_type, created_at);
CREATE INDEX IF NOT EXISTS merchant_channel_events_root_idx
  ON public.merchant_channel_events (root_manager_id, created_at);

-- 3. 注册归因（一个账号在一个渠道上只记一次）
CREATE TABLE IF NOT EXISTS public.merchant_channel_signups (
  channel_code text NOT NULL,
  root_manager_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  is_new_user boolean NOT NULL,                  -- 账号创建距归因 30 分钟内 = 新注册
  user_created_at timestamptz NOT NULL,
  source text NOT NULL DEFAULT 'unknown',
  entry_path text,                               -- qr | link | open_tag | web | sms
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (channel_code, user_id)
);

CREATE INDEX IF NOT EXISTS merchant_channel_signups_root_idx
  ON public.merchant_channel_signups (root_manager_id, created_at);

-- 4. RLS：读策略放行已登录用户（实际数据隔离在 RPC 里按 root_manager_id 过滤）；
--    写策略全关——events/signups 只能 service_role 经 RPC 写入；channels 由 RPC 写。
ALTER TABLE public.merchant_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.merchant_channel_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.merchant_channel_signups ENABLE ROW LEVEL SECURITY;

-- channels 读：不直接给表读权限，全部走 RPC（SECURITY DEFINER 内部按 root 过滤）
-- 这里不给 anon/authenticated 表级 GRANT，强制走 RPC。

-- ─────────────────────────────────────────────────────────────────────
-- RPC：渠道 CRUD（全部 SECURITY DEFINER，内部按 auth.uid() 解析企业根）
-- ─────────────────────────────────────────────────────────────────────

-- 列渠道（含漏斗汇总）
CREATE OR REPLACE FUNCTION public.list_merchant_channels(
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0,
  p_search text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_search text;
  v_total int;
  v_items jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  v_search := NULLIF(btrim(COALESCE(p_search, '')), '');

  SELECT count(*) INTO v_total
  FROM public.merchant_channels c
  WHERE c.root_manager_id = v_root
    AND (v_search IS NULL OR c.name ILIKE '%' || v_search || '%' OR c.code ILIKE '%' || v_search || '%');

  SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row.created_at DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      c.id, c.code, c.name, c.category, c.target_page, c.remark, c.is_active,
      c.qr_mime_type, c.qr_generated_at, c.qr_app_id,
      c.created_at, c.updated_at,
      (SELECT count(*) FROM public.merchant_channel_events e
        WHERE e.channel_code = c.code AND e.event_type = 'scan') AS scans,
      (SELECT count(DISTINCT e.visitor_key) FROM public.merchant_channel_events e
        WHERE e.channel_code = c.code AND e.event_type = 'scan') AS scan_visitors,
      (SELECT count(*) FROM public.merchant_channel_events e
        WHERE e.channel_code = c.code AND e.event_type = 'click') AS clicks,
      (SELECT count(*) FROM public.merchant_channel_signups s
        WHERE s.channel_code = c.code) AS signups,
      (SELECT count(*) FROM public.merchant_channel_signups s
        WHERE s.channel_code = c.code AND s.is_new_user) AS new_signups
    FROM public.merchant_channels c
    WHERE c.root_manager_id = v_root
      AND (v_search IS NULL OR c.name ILIKE '%' || v_search || '%' OR c.code ILIKE '%' || v_search || '%')
    ORDER BY c.created_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
    OFFSET GREATEST(COALESCE(p_offset, 0), 0)
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

-- 建渠道（生成 8 位 base62 短码，冲突重试）
CREATE OR REPLACE FUNCTION public.create_merchant_channel(
  p_name text,
  p_category text DEFAULT 'other',
  p_target_page text DEFAULT 'pages/index/index',
  p_remark text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_code text;
  v_attempt int := 0;
  v_row public.merchant_channels%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;
  IF btrim(COALESCE(p_name, '')) = '' THEN
    RAISE EXCEPTION '渠道名称不能为空' USING ERRCODE = '22023';
  END IF;

  -- 生成 8 位 base62 短码，撞唯一约束换候选重试
  LOOP
    v_code := '';
    FOR i IN 1..8 LOOP
      v_code := v_code || substr('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789',
                                 1 + floor(random() * 62)::int, 1);
    END LOOP;
    BEGIN
      INSERT INTO public.merchant_channels
        (root_manager_id, code, name, category, target_page, remark, created_by)
      VALUES
        (v_root, v_code, btrim(p_name), COALESCE(btrim(p_category), 'other'),
         COALESCE(NULLIF(btrim(p_target_page), ''), 'pages/index/index'),
         NULLIF(btrim(COALESCE(p_remark, '')), ''), v_uid)
      RETURNING * INTO v_row;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      v_attempt := v_attempt + 1;
      IF v_attempt >= 8 THEN
        RAISE EXCEPTION '渠道码生成冲突，请重试' USING ERRCODE = '23505';
      END IF;
    END;
  END LOOP;

  RETURN to_jsonb(v_row);
END;
$function$;

-- 更新渠道（name/category/remark/is_active/target_page；code 不可改）
CREATE OR REPLACE FUNCTION public.update_merchant_channel(
  p_code text,
  p_name text DEFAULT NULL,
  p_category text DEFAULT NULL,
  p_target_page text DEFAULT NULL,
  p_remark text DEFAULT NULL,
  p_is_active boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_row public.merchant_channels%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  UPDATE public.merchant_channels SET
    name = COALESCE(NULLIF(btrim(p_name), ''), name),
    category = COALESCE(NULLIF(btrim(p_category), ''), category),
    target_page = COALESCE(NULLIF(btrim(p_target_page), ''), target_page),
    remark = CASE WHEN p_remark IS NULL THEN remark ELSE NULLIF(btrim(p_remark), '') END,
    is_active = COALESCE(p_is_active, is_active),
    updated_at = now()
  WHERE code = btrim(p_code) AND root_manager_id = v_root
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION '渠道不存在或无权操作' USING ERRCODE = '42501';
  END IF;
  RETURN to_jsonb(v_row);
END;
$function$;

-- 删除渠道（软删：is_active=false；硬删会让历史埋点变孤儿，不提供）
CREATE OR REPLACE FUNCTION public.delete_merchant_channel(p_code text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;
  UPDATE public.merchant_channels
  SET is_active = false, updated_at = now()
  WHERE code = btrim(p_code) AND root_manager_id = v_root;
  IF NOT FOUND THEN
    RAISE EXCEPTION '渠道不存在或无权操作' USING ERRCODE = '42501';
  END IF;
  RETURN true;
END;
$function$;

-- 记录小程序码已生成（EF 调微信成功后回写）
CREATE OR REPLACE FUNCTION public.mark_merchant_channel_qr(
  p_code text,
  p_mime_type text,
  p_app_id text
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
BEGIN
  -- service_role 调用（auth.uid() 可能为空）：按 code 定位，不做商户校验
  -- EF 已在生成前校验过调用者权限
  UPDATE public.merchant_channels
  SET qr_mime_type = p_mime_type,
      qr_app_id = p_app_id,
      qr_generated_at = now(),
      updated_at = now()
  WHERE code = btrim(p_code);
  IF NOT FOUND THEN
    RAISE EXCEPTION '渠道不存在' USING ERRCODE = '42704';
  END IF;
  RETURN true;
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────
-- RPC：埋点（EF service_role 调用）
-- ─────────────────────────────────────────────────────────────────────

-- 到访/点击埋点：校验渠道 + 判重(10min) + 限流(200/min) + 写入
CREATE OR REPLACE FUNCTION public.track_merchant_channel_visit(
  p_code text,
  p_visitor text,
  p_source text,
  p_event text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_channel public.merchant_channels%ROWTYPE;
  v_recent int;
  v_rate int;
  v_allowed_sources text[] := ARRAY['qr','link','open_tag','web','share','sms','unknown'];
  v_allowed_events text[] := ARRAY['scan','click'];
BEGIN
  -- 参数校验
  IF p_code !~ '^[A-Za-z0-9]{8}$' THEN
    RETURN jsonb_build_object('tracked', false, 'reason', 'BAD_CODE');
  END IF;
  IF p_visitor IS NULL OR length(p_visitor) < 8 OR length(p_visitor) > 64 THEN
    RETURN jsonb_build_object('tracked', false, 'reason', 'BAD_VISITOR');
  END IF;
  IF NOT (p_source = ANY(v_allowed_sources)) THEN
    p_source := 'unknown';
  END IF;
  IF NOT (p_event = ANY(v_allowed_events)) THEN
    RETURN jsonb_build_object('tracked', false, 'reason', 'BAD_EVENT');
  END IF;

  SELECT * INTO v_channel FROM public.merchant_channels WHERE code = p_code;
  IF NOT FOUND OR NOT v_channel.is_active THEN
    RETURN jsonb_build_object('tracked', false, 'reason', 'NOT_CHANNEL');
  END IF;

  -- 顾问锁：按 事件+渠道 串行，保证限流/判重准确
  PERFORM pg_advisory_xact_lock(hashtext('mct:' || p_event || ':' || p_code));

  -- 判重：同 visitor + channel + event 10 分钟内已存在
  SELECT count(*) INTO v_recent
  FROM public.merchant_channel_events
  WHERE channel_code = p_code
    AND event_type = p_event
    AND visitor_key = p_visitor
    AND created_at > now() - interval '10 minutes';
  IF v_recent > 0 THEN
    RETURN jsonb_build_object('tracked', false, 'reason', 'DEDUPED');
  END IF;

  -- 限流：同 channel + event 1 分钟内 ≥ 200
  SELECT count(*) INTO v_rate
  FROM public.merchant_channel_events
  WHERE channel_code = p_code
    AND event_type = p_event
    AND created_at > now() - interval '1 minute';
  IF v_rate >= 200 THEN
    RETURN jsonb_build_object('tracked', false, 'reason', 'RATE_LIMITED');
  END IF;

  INSERT INTO public.merchant_channel_events
    (channel_code, root_manager_id, event_type, visitor_key, source)
  VALUES
    (p_code, v_channel.root_manager_id, p_event, p_visitor, p_source);

  RETURN jsonb_build_object('tracked', true);
END;
$function$;

-- 注册归因：登录用户上报，一个账号一个渠道只记一次
CREATE OR REPLACE FUNCTION public.attribute_merchant_channel_user(
  p_code text,
  p_source text DEFAULT 'unknown',
  p_entry_path text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_channel public.merchant_channels%ROWTYPE;
  v_user_created timestamptz;
  v_is_new boolean;
  v_allowed_paths text[] := ARRAY['qr','link','open_tag','web','share','sms'];
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF p_code !~ '^[A-Za-z0-9]{8}$' THEN
    RETURN jsonb_build_object('attributed', false, 'reason', 'BAD_CODE');
  END IF;
  IF NOT (p_source = ANY(ARRAY['qr','link','open_tag','web','share','sms','unknown'])) THEN
    p_source := 'unknown';
  END IF;
  IF p_entry_path IS NOT NULL AND NOT (p_entry_path = ANY(v_allowed_paths)) THEN
    p_entry_path := NULL;
  END IF;

  SELECT * INTO v_channel FROM public.merchant_channels WHERE code = p_code;
  IF NOT FOUND OR NOT v_channel.is_active THEN
    RETURN jsonb_build_object('attributed', false, 'reason', 'NOT_CHANNEL');
  END IF;

  SELECT created_at INTO v_user_created FROM auth.users WHERE id = v_uid;
  v_is_new := (v_user_created IS NOT NULL AND v_user_created >= now() - interval '30 minutes');

  INSERT INTO public.merchant_channel_signups
    (channel_code, root_manager_id, user_id, is_new_user, user_created_at, source, entry_path)
  VALUES
    (p_code, v_channel.root_manager_id, v_uid, v_is_new,
     COALESCE(v_user_created, now()), p_source, p_entry_path)
  ON CONFLICT (channel_code, user_id) DO NOTHING;

  RETURN jsonb_build_object('attributed', true, 'is_new_user', v_is_new);
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────
-- RPC：漏斗统计（按时间窗，商户根隔离）
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.merchant_channel_stats(
  p_days int DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_since timestamptz;
  v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;
  v_since := now() - (GREATEST(COALESCE(p_days, 30), 1) || ' days')::interval;

  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.total_scans DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      c.code, c.name, c.category, c.is_active,
      COALESCE((SELECT count(*) FROM public.merchant_channel_events e
        WHERE e.channel_code = c.code AND e.event_type='scan' AND e.created_at >= v_since), 0) AS scans,
      COALESCE((SELECT count(DISTINCT e.visitor_key) FROM public.merchant_channel_events e
        WHERE e.channel_code = c.code AND e.event_type='scan' AND e.created_at >= v_since), 0) AS scan_visitors,
      COALESCE((SELECT count(*) FROM public.merchant_channel_events e
        WHERE e.channel_code = c.code AND e.event_type='click' AND e.created_at >= v_since), 0) AS clicks,
      COALESCE((SELECT count(*) FROM public.merchant_channel_signups s
        WHERE s.channel_code = c.code AND s.created_at >= v_since), 0) AS signups,
      COALESCE((SELECT count(*) FROM public.merchant_channel_signups s
        WHERE s.channel_code = c.code AND s.is_new_user AND s.created_at >= v_since), 0) AS new_signups
    FROM public.merchant_channels c
    WHERE c.root_manager_id = v_root
  ) r;

  RETURN jsonb_build_object('items', v_rows, 'days', GREATEST(COALESCE(p_days, 30), 1));
END;
$function$;

-- 权限：渠道 CRUD/统计 给 authenticated；埋点/归因/标记二维码给 service_role
REVOKE ALL ON FUNCTION public.list_merchant_channels(int,int,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_merchant_channels(int,int,text) TO authenticated;
REVOKE ALL ON FUNCTION public.create_merchant_channel(text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_merchant_channel(text,text,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.update_merchant_channel(text,text,text,text,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_merchant_channel(text,text,text,text,text,boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.delete_merchant_channel(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_merchant_channel(text) TO authenticated;
REVOKE ALL ON FUNCTION public.merchant_channel_stats(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.merchant_channel_stats(int) TO authenticated;

REVOKE ALL ON FUNCTION public.track_merchant_channel_visit(text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.track_merchant_channel_visit(text,text,text,text) TO service_role;
REVOKE ALL ON FUNCTION public.attribute_merchant_channel_user(text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.attribute_merchant_channel_user(text,text,text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.mark_merchant_channel_qr(text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_merchant_channel_qr(text,text,text) TO service_role;

NOTIFY pgrst, 'reload schema';
