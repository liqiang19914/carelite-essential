-- 渠道推广：微信跳转短链（URL Link, wxmpurl.cn）支持。
-- 微信 wxa/generate_urllink 生成的短链 30 天有效，外部浏览器点击可直接唤起微信进小程序。
-- 与小程序码（永久）不同，URL Link 有有效期，到期需重新生成（EF 到期前 2 天自动换新）。

ALTER TABLE public.merchant_channels
  ADD COLUMN IF NOT EXISTS url_link text,
  ADD COLUMN IF NOT EXISTS url_link_expires_at timestamptz;

-- 回写渠道的微信 URL Link（EF service_role 调用，生成成功后落库）
CREATE OR REPLACE FUNCTION public.mark_merchant_channel_link(
  p_code text,
  p_url_link text,
  p_expires_at timestamptz
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  -- service_role 调用（auth.uid() 可能为空）：按 code 定位，不做商户校验
  -- EF 已在生成前校验过调用者权限
  UPDATE public.merchant_channels
  SET url_link = p_url_link,
      url_link_expires_at = p_expires_at,
      updated_at = now()
  WHERE code = btrim(p_code);
  IF NOT FOUND THEN
    RAISE EXCEPTION '渠道不存在' USING ERRCODE = '42704';
  END IF;
  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.mark_merchant_channel_link(text, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_merchant_channel_link(text, text, timestamptz) TO service_role;

-- 单渠道读取（EF 用）：带上 URL Link 与有效期，供 /go 跳转判断与短链缓存
DROP FUNCTION IF EXISTS public.get_merchant_channel_for_code(text);
CREATE OR REPLACE FUNCTION public.get_merchant_channel_for_code(p_code text)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT to_jsonb(t) FROM (
    SELECT c.code, c.root_manager_id, c.is_active, c.target_page,
           c.url_link, c.url_link_expires_at
    FROM public.merchant_channels c
    WHERE c.code = p_code
    LIMIT 1
  ) t;
$$;

REVOKE ALL ON FUNCTION public.get_merchant_channel_for_code(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_merchant_channel_for_code(text) TO service_role;

-- 渠道列表（前端用）：返回字段补上 URL Link / 有效期；漏斗日期范围参数保持不变
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

NOTIFY pgrst, 'reload schema';
