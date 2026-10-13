-- 渠道推广：列表漏斗统计支持按日期范围筛选。
-- 漏斗（扫码/点击/注册/新客）按「事件发生时间」created_at 统计：
--   p_date_from / p_date_to 均为 timestamptz，半开区间 [from, to)；
--   不传时默认近 30 天（与列表列标题「近30天累计」口径对齐）。
-- 渠道本身的分页/搜索不受日期影响（日期只收敛漏斗数字）。

DROP FUNCTION IF EXISTS public.list_merchant_channels(int, int, text);

CREATE OR REPLACE FUNCTION public.list_merchant_channels(
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0,
  p_search text DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_search text;
  v_from timestamptz;
  v_to timestamptz;
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
  -- 漏斗统计窗口：默认近 30 天；to 留空表示至今（半开区间 [from, to)）
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
          AND (v_to IS NULL OR s.created_at < v_to)) AS new_signups
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

REVOKE ALL ON FUNCTION public.list_merchant_channels(int, int, text, timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_merchant_channels(int, int, text, timestamptz, timestamptz) TO authenticated;
