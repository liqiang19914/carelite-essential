CREATE OR REPLACE FUNCTION public.eqa_probe_2(p_x TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN TRIM(COALESCE(p_x, ''));
END;
$function$;