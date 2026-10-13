CREATE OR REPLACE FUNCTION public.test_probe_sp3() RETURNS text
LANGUAGE plpgsql
SET search_path = 'public'
AS $function$
BEGIN
  RETURN generate_manager_invite_code();
END;
$function$;

SELECT public.test_probe_sp3();