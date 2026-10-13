CREATE OR REPLACE FUNCTION public.eqa_probe_3(p_x TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO enterprise_qa_faqs (id, question, answer, keywords, created_at, updated_at)
  VALUES (gen_random_uuid(), p_x, p_x, '{}', now(), now())
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;