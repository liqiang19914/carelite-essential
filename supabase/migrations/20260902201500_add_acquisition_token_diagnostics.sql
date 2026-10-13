CREATE OR REPLACE FUNCTION public.admin_get_acquisition_token_diagnostics(p_tokens text[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'permission denied';
  END IF;
  IF p_tokens IS NULL OR cardinality(p_tokens) < 1 OR cardinality(p_tokens) > 20 THEN
    RAISE EXCEPTION 'invalid tokens';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'tracking_token', t.token,
    'session_exists', s.tracking_token IS NOT NULL,
    'session_created_at', s.created_at,
    'utm_source', COALESCE(s.utm_source, ''),
    'wecom_added_event', EXISTS (
      SELECT 1 FROM public.landing_conversion_events e
      WHERE e.session_id = s.session_id AND e.event_type = 'wecom_added'
    ),
    'conversion_report_status', COALESCE(r.status, ''),
    'conversion_report_error', COALESCE(r.error_message, '')
  ) ORDER BY t.token), '[]'::jsonb)
  INTO result
  FROM unnest(p_tokens) AS t(token)
  LEFT JOIN public.acquisition_attribution_sessions s ON s.tracking_token = t.token
  LEFT JOIN public.acquisition_conversion_reports r
    ON r.tracking_token = t.token AND r.event_type = 'wecom_added';
  RETURN result;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_get_acquisition_token_diagnostics(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_get_acquisition_token_diagnostics(text[]) TO authenticated;
