CREATE OR REPLACE FUNCTION public.qa_verify_debug_claims()
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN jsonb_build_object(
    'jwt', COALESCE(current_setting('request.jwt.claims', true), 'none')::jsonb,
    'role', COALESCE(current_setting('request.jwt.claim.role', true), 'none'),
    'session_user', session_user,
    'current_user', current_user
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.qa_verify_debug_claims() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qa_verify_debug_claims() TO anon;
GRANT EXECUTE ON FUNCTION public.qa_verify_debug_claims() TO authenticated;
GRANT EXECUTE ON FUNCTION public.qa_verify_debug_claims() TO service_role;