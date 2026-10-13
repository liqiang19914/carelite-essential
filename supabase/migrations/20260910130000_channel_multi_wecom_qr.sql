-- ─────────────────────────────────────────────────────────────────────
-- 渠道任务墙：企微好友二维码支持多张，访客间轮流分配（不同二维码=不同顾问）
--
-- 存储：merchant_channels.wecom_qr_images jsonb（字符串数组，与旧单图同构：
--   存 data URL），旧字段 wecom_qr_image_url 保留并镜像第 1 张，兼容旧消费方。
-- 分配：get_merchant_channel_landing 对「同一访客」稳定取模
--   （visitor_key → auth.uid() → 随机兜底），同一用户刷新/重进看到的永远是
--   同一个顾问的码，避免今天加 A 明天看到 B；不同访客自然均摊到各顾问。
-- 上限：6 张，单张大小沿用前端 2MB 限制。
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.merchant_channels
  ADD COLUMN IF NOT EXISTS wecom_qr_images jsonb NOT NULL DEFAULT '[]'::jsonb;

-- 旧数据：单图回填成单元素数组
UPDATE public.merchant_channels
SET wecom_qr_images = jsonb_build_array(wecom_qr_image_url)
WHERE COALESCE(btrim(wecom_qr_image_url), '') <> ''
  AND COALESCE(jsonb_array_length(wecom_qr_images), 0) = 0;

-- ── create：增加 p_wecom_qr_images（旧 8 参签名废弃） ─────────────────
DROP FUNCTION IF EXISTS public.create_merchant_channel(text, text, text, text, uuid, jsonb, text, jsonb);

CREATE OR REPLACE FUNCTION public.create_merchant_channel(
  p_name text,
  p_category text DEFAULT 'other',
  p_target_page text DEFAULT 'pages/index/index',
  p_remark text DEFAULT NULL,
  p_root_manager_id uuid DEFAULT NULL,
  p_landing_tasks jsonb DEFAULT NULL,
  p_wecom_qr_image_url text DEFAULT NULL,
  p_landing_config jsonb DEFAULT '{}'::jsonb,
  p_wecom_qr_images jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_root uuid := COALESCE(p_root_manager_id, public.get_enterprise_root_manager_id(auth.uid()));
  v_code text;
  v_tasks text[];
  v_images jsonb := '[]'::jsonb;
  v_first text;
BEGIN
  IF v_root IS NULL THEN RAISE EXCEPTION '未登录或无企业归属' USING ERRCODE = '28000'; END IF;
  IF COALESCE(btrim(p_name), '') = '' THEN RAISE EXCEPTION '渠道名称不能为空' USING ERRCODE = '23505'; END IF;

  v_tasks := CASE WHEN jsonb_typeof(p_landing_tasks) = 'array'
                  THEN ARRAY(SELECT jsonb_array_elements_text(p_landing_tasks))
                  ELSE '{}' END;
  IF NOT (v_tasks <@ ARRAY['wecom_qr','phone_auth','company_info']) THEN
    RAISE EXCEPTION 'landing_tasks 只能包含 wecom_qr / phone_auth / company_info';
  END IF;

  IF p_wecom_qr_images IS NOT NULL THEN
    IF jsonb_typeof(p_wecom_qr_images) <> 'array' THEN
      RAISE EXCEPTION 'wecom_qr_images 必须是数组' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(p_wecom_qr_images) > 6 THEN
      RAISE EXCEPTION '企微二维码最多上传 6 张' USING ERRCODE = '22023';
    END IF;
    SELECT COALESCE(jsonb_agg(e), '[]'::jsonb) INTO v_images
    FROM jsonb_array_elements(p_wecom_qr_images) e
    WHERE jsonb_typeof(e) = 'string' AND btrim(e #>> '{}') <> '';
  END IF;

  -- 新数组为空时回退兼容旧单图入参
  IF jsonb_array_length(v_images) = 0 AND COALESCE(btrim(p_wecom_qr_image_url), '') <> '' THEN
    v_images := jsonb_build_array(NULLIF(btrim(p_wecom_qr_image_url), ''));
  END IF;
  v_first := NULLIF(btrim(v_images ->> 0), '');

  v_code := public.generate_short_code(8);
  WHILE EXISTS (SELECT 1 FROM public.merchant_channels WHERE code = v_code) LOOP
    v_code := public.generate_short_code(8);
  END LOOP;

  INSERT INTO public.merchant_channels (
    code, name, category, target_page, remark, root_manager_id,
    landing_tasks, wecom_qr_image_url, wecom_qr_images, landing_config
  ) VALUES (
    v_code, btrim(p_name), COALESCE(NULLIF(btrim(p_category), ''), 'other'),
    COALESCE(NULLIF(btrim(p_target_page), ''), 'pages/index/index'),
    NULLIF(btrim(COALESCE(p_remark, '')), ''), v_root,
    v_tasks, v_first, v_images,
    COALESCE(p_landing_config, '{}'::jsonb)
  );

  RETURN public.get_merchant_channel_for_code(v_code);
END;
$$;

REVOKE ALL ON FUNCTION public.create_merchant_channel(text, text, text, text, uuid, jsonb, text, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_merchant_channel(text, text, text, text, uuid, jsonb, text, jsonb, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_merchant_channel(text, text, text, text, uuid, jsonb, text, jsonb, jsonb) TO service_role;

-- ── update：增加 p_wecom_qr_images（NULL=不改；[]=显式清空） ───────────
DROP FUNCTION IF EXISTS public.update_merchant_channel(text, text, text, text, text, boolean, jsonb, text, jsonb);

CREATE OR REPLACE FUNCTION public.update_merchant_channel(
  p_code text,
  p_name text DEFAULT NULL,
  p_category text DEFAULT NULL,
  p_target_page text DEFAULT NULL,
  p_remark text DEFAULT NULL,
  p_is_active boolean DEFAULT NULL,
  p_landing_tasks jsonb DEFAULT NULL,
  p_wecom_qr_image_url text DEFAULT NULL,
  p_landing_config jsonb DEFAULT NULL,
  p_wecom_qr_images jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_root uuid := public.get_enterprise_root_manager_id(auth.uid());
  v_tasks text[];
  v_images jsonb;
  v_first text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.merchant_channels WHERE code = p_code AND root_manager_id = v_root
  ) THEN RAISE EXCEPTION '渠道不存在或无权限' USING ERRCODE = '42501'; END IF;

  IF p_landing_tasks IS NOT NULL THEN
    IF jsonb_typeof(p_landing_tasks) <> 'array' THEN
      RAISE EXCEPTION 'landing_tasks 必须是数组';
    END IF;
    v_tasks := ARRAY(SELECT jsonb_array_elements_text(p_landing_tasks));
    IF NOT (v_tasks <@ ARRAY['wecom_qr','phone_auth','company_info']) THEN
      RAISE EXCEPTION 'landing_tasks 只能包含 wecom_qr / phone_auth / company_info';
    END IF;
  END IF;

  IF p_wecom_qr_images IS NOT NULL THEN
    IF jsonb_typeof(p_wecom_qr_images) <> 'array' THEN
      RAISE EXCEPTION 'wecom_qr_images 必须是数组' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(p_wecom_qr_images) > 6 THEN
      RAISE EXCEPTION '企微二维码最多上传 6 张' USING ERRCODE = '22023';
    END IF;
    SELECT COALESCE(jsonb_agg(e), '[]'::jsonb) INTO v_images
    FROM jsonb_array_elements(p_wecom_qr_images) e
    WHERE jsonb_typeof(e) = 'string' AND btrim(e #>> '{}') <> '';
  END IF;
  -- 未传多图数组时，旧单图入参仍可改图（转成单元素数组）
  IF v_images IS NULL AND p_wecom_qr_image_url IS NOT NULL THEN
    v_images := CASE
      WHEN btrim(p_wecom_qr_image_url) = '' THEN '[]'::jsonb
      ELSE jsonb_build_array(btrim(p_wecom_qr_image_url)) END;
  END IF;
  IF v_images IS NOT NULL THEN
    v_first := NULLIF(btrim(v_images ->> 0), '');
  END IF;

  UPDATE public.merchant_channels c SET
    name = COALESCE(NULLIF(btrim(p_name), ''), c.name),
    category = COALESCE(NULLIF(btrim(p_category), ''), c.category),
    target_page = COALESCE(NULLIF(btrim(p_target_page), ''), c.target_page),
    remark = CASE WHEN p_remark IS NULL THEN c.remark ELSE NULLIF(btrim(p_remark), '') END,
    is_active = COALESCE(p_is_active, c.is_active),
    landing_tasks = COALESCE(v_tasks, c.landing_tasks),
    wecom_qr_image_url = COALESCE(v_first, c.wecom_qr_image_url),
    wecom_qr_images = COALESCE(v_images, c.wecom_qr_images),
    landing_config = COALESCE(p_landing_config, c.landing_config),
    updated_at = now()
  WHERE c.code = p_code;

  RETURN public.get_merchant_channel_for_code(p_code);
END;
$$;

REVOKE ALL ON FUNCTION public.update_merchant_channel(text, text, text, text, text, boolean, jsonb, text, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_merchant_channel(text, text, text, text, text, boolean, jsonb, text, jsonb, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_merchant_channel(text, text, text, text, text, boolean, jsonb, text, jsonb, jsonb) TO service_role;

-- ── list：补返 wecom_qr_images（后台编辑弹窗回填多图） ─────────────────
DROP FUNCTION IF EXISTS public.list_merchant_channels(int, int, text, timestamptz, timestamptz);
CREATE OR REPLACE FUNCTION public.list_merchant_channels(
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0,
  p_search text DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_search text;
  v_from timestamptz;
  v_to timestamptz;
  v_total int;
  v_items jsonb;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION '请先登录' USING ERRCODE = '28000'; END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501'; END IF;

  v_search := NULLIF(btrim(COALESCE(p_search, '')), '');
  v_from := COALESCE(p_date_from, now() - interval '30 days');
  v_to := p_date_to;

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
      c.url_link, c.url_link_expires_at,
      c.landing_tasks, c.wecom_qr_image_url, c.wecom_qr_images, c.landing_config,
      c.created_at, c.updated_at,
      (SELECT count(*) FROM public.merchant_channel_events e
        WHERE e.channel_code = c.code AND e.event_type = 'scan'
          AND e.created_at >= v_from
          AND (v_to IS NULL OR e.created_at < v_to)) AS scans,
      (SELECT count(DISTINCT e.visitor_key) FROM public.merchant_channel_events e
        WHERE e.channel_code = c.code AND e.event_type = 'scan'
          AND e.created_at >= v_from
          AND (v_to IS NULL OR e.created_at < v_to)) AS scan_visitors,
      (SELECT count(*) FROM public.merchant_channel_events e
        WHERE e.channel_code = c.code AND e.event_type = 'click'
          AND e.created_at >= v_from
          AND (v_to IS NULL OR e.created_at < v_to)) AS clicks,
      (SELECT count(*) FROM public.merchant_channel_signups s
        WHERE s.channel_code = c.code
          AND s.created_at >= v_from
          AND (v_to IS NULL OR s.created_at < v_to)) AS signups,
      (SELECT count(*) FROM public.merchant_channel_signups s
        WHERE s.channel_code = c.code AND s.is_new_user
          AND s.created_at >= v_from
          AND (v_to IS NULL OR s.created_at < v_to)) AS new_signups,
      (SELECT count(DISTINCT t.visitor_key) FROM public.merchant_channel_tasks t
        WHERE t.channel_code = c.code AND t.task_name = 'wecom_qr'
          AND t.completed_at >= v_from
          AND (v_to IS NULL OR t.completed_at < v_to)) AS tasks_wecom_qr,
      (SELECT count(DISTINCT t.user_id) FROM public.merchant_channel_tasks t
        WHERE t.channel_code = c.code AND t.task_name = 'phone_auth' AND t.user_id IS NOT NULL
          AND t.completed_at >= v_from
          AND (v_to IS NULL OR t.completed_at < v_to)) AS tasks_phone_auth,
      (SELECT count(*) FROM public.merchant_channel_tasks t
        WHERE t.channel_code = c.code AND t.task_name = 'company_info'
          AND t.completed_at >= v_from
          AND (v_to IS NULL OR t.completed_at < v_to)) AS tasks_company_info
    FROM public.merchant_channels c
    WHERE c.root_manager_id = v_root
      AND (v_search IS NULL OR c.name ILIKE '%' || v_search || '%' OR c.code ILIKE '%' || v_search || '%')
    ORDER BY c.created_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
    OFFSET GREATEST(COALESCE(p_offset, 0), 0)
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$$;

REVOKE ALL ON FUNCTION public.list_merchant_channels(int,int,text,timestamptz,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_merchant_channels(int,int,text,timestamptz,timestamptz) TO authenticated;

-- ── landing：按访客稳定选一张（同签名 CREATE OR REPLACE 直接替换） ──────
CREATE OR REPLACE FUNCTION public.get_merchant_channel_landing(
  p_code text,
  p_visitor_key text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_channel jsonb;
  v_brand_name text;
  v_done jsonb;
  v_images jsonb := '[]'::jsonb;
  v_n int;
  v_idx int;
  v_seed text;
  v_qr text;
BEGIN
  SELECT to_jsonb(c) INTO v_channel
  FROM public.merchant_channels c
  WHERE c.code = p_code AND c.is_active = true;

  IF v_channel IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NOT_FOUND');
  END IF;

  v_root := v_channel->>'root_manager_id';
  SELECT COALESCE(m.brand_name, m.app_name, '') INTO v_brand_name
  FROM public.manager_miniprograms m
  WHERE m.manager_id = v_root AND m.is_enabled = true
  LIMIT 1;

  IF auth.uid() IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(DISTINCT task_name), '[]'::jsonb) INTO v_done
    FROM (
      SELECT task_name FROM public.merchant_channel_tasks
      WHERE channel_code = p_code
        AND (
          user_id = auth.uid()
          OR (p_visitor_key IS NOT NULL AND visitor_key = p_visitor_key)
        )
      UNION
      SELECT 'phone_auth'::text
      WHERE EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND COALESCE(btrim(phone), '') <> ''
      )
    ) sub;
  ELSIF p_visitor_key IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(task_name), '[]'::jsonb) INTO v_done
    FROM (SELECT DISTINCT task_name FROM public.merchant_channel_tasks
          WHERE channel_code = p_code AND visitor_key = p_visitor_key) sub;
  ELSE
    v_done := '[]'::jsonb;
  END IF;

  -- 归一化有效二维码：多图列优先，空则回退旧单图字段
  SELECT COALESCE(jsonb_agg(e), '[]'::jsonb) INTO v_images
  FROM jsonb_array_elements(COALESCE(v_channel->'wecom_qr_images', '[]'::jsonb)) e
  WHERE jsonb_typeof(e) = 'string' AND btrim(e #>> '{}') <> '';

  IF jsonb_array_length(v_images) = 0 AND COALESCE(btrim(v_channel->>'wecom_qr_image_url'), '') <> '' THEN
    v_images := jsonb_build_array(v_channel->>'wecom_qr_image_url');
  END IF;

  v_n := jsonb_array_length(v_images);
  IF v_n > 0 THEN
    -- 同一访客（visitor cookie / 登录用户）恒定取同一张；都拿不到才随机
    v_seed := COALESCE(NULLIF(btrim(COALESCE(p_visitor_key, '')), ''), auth.uid()::text);
    IF v_seed IS NOT NULL THEN
      v_idx := abs(hashtextextended(v_seed, 0)) % v_n;
    ELSE
      v_idx := floor(random() * v_n)::int;
    END IF;
    v_qr := v_images ->> v_idx;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'skip', COALESCE(jsonb_array_length(COALESCE(v_channel->'landing_tasks', '[]'::jsonb)), 0) = 0,
    'channel', jsonb_build_object(
      'code', v_channel->>'code',
      'name', v_channel->>'name',
      'landing_enabled', COALESCE((v_channel->>'landing_enabled')::boolean, true),
      'landing_tasks', COALESCE(v_channel->'landing_tasks', '[]'::jsonb),
      'landing_config', COALESCE(v_channel->'landing_config', '{}'::jsonb),
      'wecom_qr_image_url', v_qr,
      'wecom_qr_count', v_n
    ),
    'brand', jsonb_build_object('name', v_brand_name),
    'completed_tasks', v_done
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';
