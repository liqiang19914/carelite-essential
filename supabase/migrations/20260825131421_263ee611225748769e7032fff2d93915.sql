CREATE OR REPLACE FUNCTION public.eqa_probe_5(p_id UUID, p_x TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO enterprise_qa_faqs (id, question, answer, keywords, created_at, updated_at)
  VALUES (p_id, p_x, p_x, '{}', now(), now())
  ON CONFLICT (id) DO UPDATE
  SET answer = EXCLUDED.answer, updated_at = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;