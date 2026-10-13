CREATE OR REPLACE FUNCTION public.qa_verify_debug_role()
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN 'current_user=' || current_user || ' session_user=' || session_user || ' jwt_role=' || COALESCE(current_setting('request.jwt.claims', true)::jsonb->>'role', 'none');
END;
$function$;

REVOKE ALL ON FUNCTION public.qa_verify_debug_role() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qa_verify_debug_role() TO anon;
GRANT EXECUTE ON FUNCTION public.qa_verify_debug_role() TO authenticated;
GRANT EXECUTE ON FUNCTION public.qa_verify_debug_role() TO service_role;