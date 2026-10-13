ALTER TABLE public.landing_conversion_events
  ADD COLUMN IF NOT EXISTS ip text NOT NULL DEFAULT '';

ALTER TABLE public.acquisition_attribution_sessions
  ADD COLUMN IF NOT EXISTS ip text NOT NULL DEFAULT '';

COMMENT ON COLUMN public.landing_conversion_events.ip IS
  '访客 IP，服务端从 x-forwarded-for 首段解析后写入；历史行为空字符串。';
COMMENT ON COLUMN public.acquisition_attribution_sessions.ip IS
  '会话最近一次事件的访客 IP，服务端解析；企微回调类事件沿用该值。';

CREATE OR REPLACE FUNCTION public.admin_list_landing_conversion_events(
  p_from timestamptz,
  p_to timestamptz,
  p_limit integer DEFAULT 500
)
RETURNS TABLE (
  event_time timestamptz,
  event_type text,
  ip text,
  utm_source text,
  utm_campaign text,
  utm_content text,
  cta_source text,
  visitor_label text,
  same_ip_events bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'permission denied';
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_from >= p_to THEN
    RAISE EXCEPTION 'invalid time range';
  END IF;

  RETURN QUERY
  WITH scoped AS (
    SELECT
      e.created_at AS happened_at,
      e.event_type AS kind,
      COALESCE(e.ip, '') AS ip_text,
      COALESCE(NULLIF(e.utm_source, ''), 'direct') AS src,
      COALESCE(e.utm_campaign, '') AS campaign,
      COALESCE(e.utm_content, '') AS content,
      COALESCE(e.cta_source, '') AS cta,
      e.visitor_id AS visitor_id,
      CASE
        WHEN COALESCE(e.ip, '') = '' THEN 0::bigint
        ELSE count(*) OVER (PARTITION BY COALESCE(e.ip, ''))
      END AS dup_count
    FROM public.landing_conversion_events e
    WHERE e.created_at >= p_from AND e.created_at < p_to
  )
  SELECT
    s.happened_at,
    s.kind,
    s.ip_text,
    s.src,
    s.campaign,
    s.content,
    s.cta,
    left(s.visitor_id, 8),
    s.dup_count
  FROM scoped s
  ORDER BY s.happened_at DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 500), 1), 1000);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_landing_conversion_events(timestamptz, timestamptz, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_landing_conversion_events(timestamptz, timestamptz, integer) TO authenticated;

COMMENT ON FUNCTION public.admin_list_landing_conversion_events(timestamptz, timestamptz, integer) IS
  '平台管理员按时间范围读取投放点击/转化明细（含访客 IP 与同 IP 重复计数）；仅 authenticated 可执行。';