CREATE OR REPLACE FUNCTION public.eqa_probe_8(
  p_question TEXT,
  p_answer TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN NULL::UUID;
END;
$function$;