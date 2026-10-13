-- 渠道任务墙：任务顺序 + 进度条开关配套
--
-- landing_tasks 是 text[]，元素顺序即客户看到的任务顺序（商户在 B 端可上下调整）；
-- 「是否显示任务进度条」存 landing_config.showProgress（jsonb，无需加列）。
--
-- 本迁移只补一处：list_merchant_channels 之前不返回 landing_config，
-- B 端编辑弹窗打开时页面文案/进度条开关无法回填（一律显示默认值）。

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
      c.landing_tasks, c.wecom_qr_image_url, c.landing_config,
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

NOTIFY pgrst, 'reload schema';
