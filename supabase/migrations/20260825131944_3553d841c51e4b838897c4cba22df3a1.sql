CREATE OR REPLACE FUNCTION public.upsert_enterprise_qa_faq(
  p_question TEXT,
  p_answer TEXT,
  p_id UUID DEFAULT NULL,
  p_keywords TEXT[] DEFAULT '{}'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_eid UUID;
  v_kw TEXT[];
  v_result UUID;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  v_eid := public.get_profile_enterprise_id(v_caller);
  IF v_eid IS NULL THEN
    RAISE EXCEPTION 'no enterprise';
  END IF;

  SELECT ARRAY(
    SELECT btrim(kw) FROM unnest(COALESCE(p_keywords, '{}'::TEXT[])) kw
    WHERE btrim(kw) <> ''
  ) INTO v_kw;
  IF array_length(v_kw, 1) IS NOT NULL AND array_length(v_kw, 1) > 10 THEN
    v_kw := v_kw[1:10];
  END IF;

  INSERT INTO public.enterprise_qa_faqs (
    id, enterprise_id, question, answer, keywords, source, source_message_id, created_by, updated_at
  )
  VALUES (
    COALESCE(p_id, gen_random_uuid()), v_eid, TRIM(p_question), TRIM(p_answer),
    COALESCE(v_kw, '{}'::TEXT[]), 'manual', NULL, v_caller, NOW()
  )
  ON CONFLICT (id) DO UPDATE
  SET question = EXCLUDED.question,
      answer = EXCLUDED.answer,
      keywords = EXCLUDED.keywords,
      updated_at = NOW()
  RETURNING id INTO v_result;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.upsert_enterprise_qa_faq(TEXT, TEXT, UUID, TEXT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_enterprise_qa_faq(TEXT, TEXT, UUID, TEXT[]) TO authenticated;