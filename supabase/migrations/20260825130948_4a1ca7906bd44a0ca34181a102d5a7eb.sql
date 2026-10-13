CREATE OR REPLACE FUNCTION public.list_enterprise_qa_faqs(
  p_query TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_eid UUID;
  v_items JSON;
  v_total INTEGER;
  v_q TEXT := NULLIF(TRIM(p_query), '');
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  v_eid := public.get_profile_enterprise_id(v_caller);
  IF v_eid IS NULL THEN
    RAISE EXCEPTION 'no enterprise';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM public.enterprise_qa_faqs q
  WHERE q.enterprise_id = v_eid
    AND (v_q IS NULL
         OR q.question ILIKE '%' || v_q || '%'
         OR q.answer ILIKE '%' || v_q || '%'
         OR EXISTS (
              SELECT 1 FROM unnest(q.keywords) kw
              WHERE btrim(kw) <> '' AND btrim(kw) ILIKE '%' || v_q || '%'
            ));

  SELECT json_agg(t) INTO v_items
  FROM (
    SELECT
      q.id,
      q.question,
      q.answer,
      q.keywords,
      q.source,
      q.source_message_id,
      q.enabled,
      q.created_at,
      q.updated_at
    FROM public.enterprise_qa_faqs q
    WHERE q.enterprise_id = v_eid
      AND (v_q IS NULL
           OR q.question ILIKE '%' || v_q || '%'
           OR q.answer ILIKE '%' || v_q || '%'
           OR EXISTS (
                SELECT 1 FROM unnest(q.keywords) kw
                WHERE btrim(kw) <> '' AND btrim(kw) ILIKE '%' || v_q || '%'
              ))
    ORDER BY q.updated_at DESC
    LIMIT GREATEST(LEAST(p_limit, 200), 1)
    OFFSET GREATEST(p_offset, 0)
  ) t;

  RETURN json_build_object(
    'items', COALESCE(v_items, '[]'::JSON),
    'total', v_total
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_qa_faqs(TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_enterprise_qa_faqs(TEXT, INTEGER, INTEGER) TO authenticated;