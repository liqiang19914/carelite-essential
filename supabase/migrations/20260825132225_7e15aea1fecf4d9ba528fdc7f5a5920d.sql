CREATE OR REPLACE FUNCTION public.match_enterprise_qa_faqs(
  p_enterprise_id UUID,
  p_query TEXT,
  p_top INTEGER DEFAULT 3
)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_q TEXT := NULLIF(TRIM(p_query), '');
  v_items JSON;
BEGIN
  IF v_q IS NULL OR p_enterprise_id IS NULL THEN
    RETURN json_build_object('items', '[]'::JSON);
  END IF;

  SELECT json_agg(t) INTO v_items
  FROM (
    SELECT
      q.id,
      q.question,
      q.answer,
      GREATEST(
        similarity(q.question, v_q),
        COALESCE(
          (SELECT MAX(similarity(kw, v_q)) FROM unnest(q.keywords) kw WHERE btrim(kw) <> ''), 0
        )
      ) AS score
    FROM public.enterprise_qa_faqs q
    WHERE q.enterprise_id = p_enterprise_id
      AND q.enabled = true
      AND (
        similarity(q.question, v_q) > 0.1
        OR EXISTS (
          SELECT 1 FROM unnest(q.keywords) kw
          WHERE btrim(kw) <> '' AND similarity(kw, v_q) > 0.1
        )
      )
    ORDER BY score DESC
    LIMIT GREATEST(LEAST(COALESCE(p_top, 3), 10), 1)
  ) t
  WHERE t.score > 0.15;

  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;

REVOKE ALL ON FUNCTION public.match_enterprise_qa_faqs(UUID, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_enterprise_qa_faqs(UUID, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_enterprise_qa_faqs(UUID, TEXT, INTEGER) TO service_role;