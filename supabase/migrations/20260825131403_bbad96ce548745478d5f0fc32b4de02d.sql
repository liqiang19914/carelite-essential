CREATE OR REPLACE FUNCTION public.eqa_probe_4(p_id UUID, p_x TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_id UUID;
BEGIN
  UPDATE enterprise_qa_faqs
  SET answer = p_x, updated_at = now()
  WHERE id = p_id
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;