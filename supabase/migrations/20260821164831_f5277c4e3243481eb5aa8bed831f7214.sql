CREATE OR REPLACE FUNCTION public.test_probe_sp2() RETURNS text
LANGUAGE plpgsql
AS $function$
BEGIN
  RETURN generate_manager_invite_code();
END;
$function$;

SELECT public.test_probe_sp2();