CREATE OR REPLACE FUNCTION public.delete_enterprise_qa_faq(p_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_eid UUID;
  v_faq public.enterprise_qa_faqs;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  v_eid := public.get_profile_enterprise_id(v_caller);
  IF v_eid IS NULL THEN
    RAISE EXCEPTION 'no enterprise';
  END IF;

  SELECT * INTO v_faq
  FROM public.enterprise_qa_faqs
  WHERE id = p_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;
  IF v_faq.enterprise_id IS DISTINCT FROM v_eid THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  UPDATE public.enterprise_qa_calibrations
  SET faq_id = NULL
  WHERE faq_id = p_id;

  DELETE FROM public.enterprise_qa_faqs WHERE id = p_id;
  RETURN TRUE;
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_enterprise_qa_faq(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_enterprise_qa_faq(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.batch_import_enterprise_qa_faqs(p_items JSONB)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_eid UUID;
  v_count INTEGER := 0;
  v_item JSONB;
  v_q TEXT;
  v_a TEXT;
  v_kw TEXT[];
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  v_eid := public.get_profile_enterprise_id(v_caller);
  IF v_eid IS NULL THEN
    RAISE EXCEPTION 'no enterprise';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION '无有效条目' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_items) > 200 THEN
    RAISE EXCEPTION '单次最多导入 200 条' USING ERRCODE = '22023';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_q := NULLIF(TRIM(COALESCE(v_item->>'question', '')), '');
    v_a := NULLIF(TRIM(COALESCE(v_item->>'answer', '')), '');
    IF v_q IS NULL OR v_a IS NULL THEN
      RAISE EXCEPTION '条目格式无效：问题与答案均不能为空' USING ERRCODE = '22023';
    END IF;
    IF char_length(v_q) > 1000 OR char_length(v_a) > 5000 THEN
      RAISE EXCEPTION '条目过长' USING ERRCODE = '22023';
    END IF;

    SELECT ARRAY(
      SELECT btrim(kw)
      FROM jsonb_array_elements_text(COALESCE(v_item->'keywords', '[]'::JSONB)) kw
      WHERE btrim(kw) <> ''
    ) INTO v_kw;
    IF array_length(v_kw, 1) IS NOT NULL AND array_length(v_kw, 1) > 10 THEN
      v_kw := v_kw[1:10];
    END IF;

    INSERT INTO public.enterprise_qa_faqs (enterprise_id, question, answer, keywords, source, created_by)
    VALUES (v_eid, v_q, v_a, COALESCE(v_kw, '{}'::TEXT[]), 'import', v_caller);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.batch_import_enterprise_qa_faqs(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.batch_import_enterprise_qa_faqs(JSONB) TO authenticated;