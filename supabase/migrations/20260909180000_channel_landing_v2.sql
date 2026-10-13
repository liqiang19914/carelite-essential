-- ─────────────────────────────────────────────────────────────────────
-- 任务墙：渠道可配置落地任务 + 企微二维码 + 任务完成漏斗
--
-- 新增字段：
--   merchant_channels.landing_tasks text[] —— 配置该渠道开启哪些任务
--   merchant_channels.wecom_qr_image_url    —— 企微好友二维码
--
-- 重建 RPC：create / update / list / get_merchant_channel_for_code
-- 扩展 list RPC 返回各任务完成数；get_merchant_channel_landing 返回配置
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.merchant_channels
  ADD COLUMN IF NOT EXISTS landing_tasks text[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS wecom_qr_image_url text;

-- 校验 landing_tasks 只能是允许值
DO $$ BEGIN
  ALTER TABLE public.merchant_channels
    ADD CONSTRAINT merchant_channels_landing_tasks_check
    CHECK (landing_tasks <@ ARRAY['wecom_qr', 'phone_auth', 'company_info']);
EXCEPTION WHEN duplicate_object THEN null; END $$;

-- ── 重建 create_merchant_channel ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.create_merchant_channel(
  p_name text,
  p_category text DEFAULT 'other',
  p_target_page text DEFAULT 'pages/index/index',
  p_remark text DEFAULT NULL,
  p_landing_tasks text[] DEFAULT '{}',
  p_wecom_qr_image_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_code text;
  v_attempt int := 0;
  v_row public.merchant_channels%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION '请先登录' USING ERRCODE = '28000'; END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501'; END IF;
  IF btrim(COALESCE(p_name, '')) = '' THEN RAISE EXCEPTION '渠道名称不能为空' USING ERRCODE = '22023'; END IF;
  IF p_landing_tasks IS NOT NULL AND NOT (p_landing_tasks <@ ARRAY['wecom_qr','phone_auth','company_info']) THEN
    RAISE EXCEPTION 'landing_tasks 只能包含 wecom_qr / phone_auth / company_info';
  END IF;

  LOOP
    v_code := '';
    FOR i IN 1..8 LOOP
      v_code := v_code || substr('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789',
                                 1 + floor(random() * 62)::int, 1);
    END LOOP;
    BEGIN
      INSERT INTO public.merchant_channels
        (root_manager_id, code, name, category, target_page, remark, landing_tasks, wecom_qr_image_url, created_by)
      VALUES
        (v_root, v_code, btrim(p_name), COALESCE(btrim(p_category), 'other'),
         COALESCE(NULLIF(btrim(p_target_page), ''), 'pages/index/index'),
         NULLIF(btrim(COALESCE(p_remark, '')), ''),
         COALESCE(p_landing_tasks, '{}'),
         NULLIF(btrim(COALESCE(p_wecom_qr_image_url, '')), ''),
         v_uid)
      RETURNING * INTO v_row;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      v_attempt := v_attempt + 1;
      IF v_attempt >= 8 THEN RAISE EXCEPTION '渠道码生成冲突，请重试' USING ERRCODE = '23505'; END IF;
    END;
  END LOOP;

  RETURN to_jsonb(v_row);
END;
$$;

REVOKE ALL ON FUNCTION public.create_merchant_channel(text,text,text,text,text[],text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_merchant_channel(text,text,text,text,text[],text) TO authenticated;

-- ── 重建 update_merchant_channel ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_merchant_channel(
  p_code text,
  p_name text DEFAULT NULL,
  p_category text DEFAULT NULL,
  p_target_page text DEFAULT NULL,
  p_remark text DEFAULT NULL,
  p_is_active boolean DEFAULT NULL,
  p_landing_tasks text[] DEFAULT NULL,
  p_wecom_qr_image_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_row public.merchant_channels%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION '请先登录' USING ERRCODE = '28000'; END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501'; END IF;
  IF p_landing_tasks IS NOT NULL AND NOT (p_landing_tasks <@ ARRAY['wecom_qr','phone_auth','company_info']) THEN
    RAISE EXCEPTION 'landing_tasks 只能包含 wecom_qr / phone_auth / company_info';
  END IF;

  UPDATE public.merchant_channels SET
    name = COALESCE(NULLIF(btrim(p_name), ''), name),
    category = COALESCE(NULLIF(btrim(p_category), ''), category),
    target_page = COALESCE(NULLIF(btrim(p_target_page), ''), target_page),
    remark = CASE WHEN p_remark IS NULL THEN remark ELSE NULLIF(btrim(p_remark), '') END,
    is_active = COALESCE(p_is_active, is_active),
    landing_tasks = COALESCE(p_landing_tasks, landing_tasks),
    wecom_qr_image_url = CASE WHEN p_wecom_qr_image_url IS NULL THEN wecom_qr_image_url ELSE NULLIF(btrim(p_wecom_qr_image_url), '') END,
    updated_at = now()
  WHERE code = btrim(p_code) AND root_manager_id = v_root
  RETURNING * INTO v_row;

  IF NOT FOUND THEN RAISE EXCEPTION '渠道不存在或无权操作' USING ERRCODE = '42501'; END IF;
  RETURN to_jsonb(v_row);
END;
$$;

REVOKE ALL ON FUNCTION public.update_merchant_channel(text,text,text,text,text,boolean,text[],text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_merchant_channel(text,text,text,text,text,boolean,text[],text) TO authenticated;

-- ── 重建 list_merchant_channels（补 landing_tasks / wecom_qr + 任务完成漏斗）──
DROP FUNCTION IF EXISTS public.list_merchant_channels(int,int,text,timestamptz,timestamptz);
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
      c.landing_tasks, c.wecom_qr_image_url,
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

-- ── 重建 get_merchant_channel_for_code（补 landing_tasks / wecom_qr）──
DROP FUNCTION IF EXISTS public.get_merchant_channel_for_code(text);
CREATE OR REPLACE FUNCTION public.get_merchant_channel_for_code(p_code text)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT to_jsonb(t) FROM (
    SELECT c.code, c.root_manager_id, c.is_active, c.target_page,
           c.url_link, c.url_link_expires_at,
           c.landing_tasks, c.wecom_qr_image_url
    FROM public.merchant_channels c
    WHERE c.code = p_code
    LIMIT 1
  ) t;
$$;

REVOKE ALL ON FUNCTION public.get_merchant_channel_for_code(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_merchant_channel_for_code(text) TO service_role;

-- ── 重建 get_merchant_channel_landing（返回 landing_tasks 配置，用于判断是否跳过）──
CREATE OR REPLACE FUNCTION public.get_merchant_channel_landing(
  p_code text,
  p_visitor_key text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_root uuid;
  v_channel jsonb;
  v_brand_name text;
  v_done jsonb;
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
    SELECT COALESCE(jsonb_agg(task_name), '[]'::jsonb) INTO v_done
    FROM (SELECT DISTINCT task_name FROM public.merchant_channel_tasks
          WHERE channel_code = p_code AND user_id = auth.uid()) sub;
  ELSIF p_visitor_key IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(task_name), '[]'::jsonb) INTO v_done
    FROM (SELECT DISTINCT task_name FROM public.merchant_channel_tasks
          WHERE channel_code = p_code AND visitor_key = p_visitor_key) sub;
  ELSE
    v_done := '[]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'skip', COALESCE(jsonb_array_length(COALESCE(v_channel->'landing_tasks', '[]'::jsonb)), 0) = 0,
    'channel', jsonb_build_object(
      'code', v_channel->>'code',
      'name', v_channel->>'name',
      'landing_tasks', COALESCE(v_channel->'landing_tasks', '[]'::jsonb),
      'wecom_qr_image_url', v_channel->>'wecom_qr_image_url'
    ),
    'brand', jsonb_build_object('name', v_brand_name),
    'completed_tasks', v_done
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_merchant_channel_landing(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_merchant_channel_landing(text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.get_merchant_channel_landing(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_merchant_channel_landing(text, text) TO service_role;

NOTIFY pgrst, 'reload schema';
