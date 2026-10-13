CREATE OR REPLACE FUNCTION public.eqa_probe_1(p_x TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN NULLIF(TRIM(p_x), '');
END;
$function$;