CREATE OR REPLACE FUNCTION public.list_help_faqs(p_audience text, p_manager_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root   uuid;
  v_result jsonb;
BEGIN
  IF p_audience IS NULL OR p_audience NOT IN ('user','manager') THEN
    RAISE EXCEPTION '非法受众类型' USING ERRCODE = '22023';
  END IF;

  v_root := public.get_membership_root_manager_id(p_manager_id);

  SELECT jsonb_agg(x ORDER BY x.is_merchant, x.sort_order, x.created_at, x.id)
  INTO v_result
  FROM (
    SELECT f.id, f.question, f.answer, f.sort_order, f.created_at,
           (f.scope = 'merchant') AS is_merchant
    FROM public.help_faqs f
    WHERE f.audience = p_audience
      AND (f.scope = 'platform' OR (f.scope = 'merchant' AND f.root_manager_id = v_root))
  ) x;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_help_faqs(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_help_faqs(text, uuid) TO anon, authenticated;