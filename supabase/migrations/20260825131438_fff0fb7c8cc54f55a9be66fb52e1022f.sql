CREATE OR REPLACE FUNCTION public.eqa_probe_6(p_kw TEXT[] DEFAULT '{}')
RETURNS TEXT[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_kw TEXT[];
BEGIN
  SELECT ARRAY(
    SELECT btrim(kw) FROM unnest(COALESCE(p_kw, '{}'::TEXT[])) kw
    WHERE btrim(kw) <> ''
  ) INTO v_kw;
  IF array_length(v_kw, 1) IS NOT NULL AND array_length(v_kw, 1) > 10 THEN
    v_kw := v_kw[1:10];
  END IF;
  RETURN v_kw;
END;
$function$;