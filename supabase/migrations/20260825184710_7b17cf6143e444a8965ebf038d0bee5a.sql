REVOKE ALL ON FUNCTION public.match_enterprise_qa_faqs(UUID, TEXT, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.match_enterprise_qa_faqs(UUID, TEXT, INTEGER) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.match_enterprise_qa_faqs(UUID, TEXT, INTEGER) TO service_role;

CREATE OR REPLACE FUNCTION public.upsert_enterprise_qa_faq(
  p_question TEXT,
  p_answer TEXT,
  p_id UUID DEFAULT NULL,
  p_keywords TEXT[] DEFAULT '{}',
  p_media JSONB DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_actor RECORD;
  v_eid UUID;
  v_kw TEXT[];
  v_result UUID;
  v_media JSONB := NULL;
  v_item JSONB;
  v_item_type TEXT;
  v_item_url TEXT;
  v_item_id TEXT;
  v_item_thumb TEXT;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  SELECT p.role, p.is_disabled INTO v_actor FROM public.profiles p WHERE p.id = v_caller;
  IF NOT FOUND OR v_actor.role IS DISTINCT FROM 'manager' OR COALESCE(v_actor.is_disabled, false) THEN
    RAISE EXCEPTION '账号已停用或无权访问' USING ERRCODE = '42501';
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

  IF p_media IS NOT NULL THEN
    IF jsonb_typeof(p_media) <> 'array' OR jsonb_array_length(p_media) > 10 THEN
      RAISE EXCEPTION '素材格式不正确' USING ERRCODE = '22023';
    END IF;
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_media) LOOP
      v_item_type := v_item->>'type';
      v_item_url := v_item->>'url';
      v_item_id := NULLIF(TRIM(COALESCE(v_item->>'id', '')), '');
      v_item_thumb := NULLIF(TRIM(COALESCE(v_item->>'thumbnail_url', '')), '');
      IF v_item_type NOT IN ('image','video') THEN
        RAISE EXCEPTION '素材类型不正确' USING ERRCODE = '22023';
      END IF;
      IF v_item_id IS NULL OR char_length(v_item_id) > 64 THEN
        RAISE EXCEPTION '素材标识不正确' USING ERRCODE = '22023';
      END IF;
      IF v_item_url IS NULL OR v_item_url !~ '^https://[^/]+\.aliyuncs\.com/' THEN
        RAISE EXCEPTION '素材地址不正确' USING ERRCODE = '22023';
      END IF;
      IF v_item_thumb IS NOT NULL AND v_item_thumb !~ '^https://[^/]+\.aliyuncs\.com/' THEN
        RAISE EXCEPTION '素材封面地址不正确' USING ERRCODE = '22023';
      END IF;
    END LOOP;
    v_media := p_media;
  END IF;

  INSERT INTO public.enterprise_qa_faqs (
    id, enterprise_id, question, answer, keywords, source, source_message_id, created_by, media, updated_at
  )
  VALUES (
    COALESCE(p_id, gen_random_uuid()), v_eid, TRIM(p_question), TRIM(p_answer),
    COALESCE(v_kw, '{}'::TEXT[]), 'manual', NULL, v_caller, COALESCE(v_media, '[]'::JSONB), NOW()
  )
  ON CONFLICT (id) DO UPDATE
  SET question = EXCLUDED.question,
      answer = EXCLUDED.answer,
      keywords = EXCLUDED.keywords,
      media = CASE WHEN v_media IS NULL THEN public.enterprise_qa_faqs.media ELSE EXCLUDED.media END,
      updated_at = NOW()
  WHERE public.enterprise_qa_faqs.enterprise_id = v_eid
  RETURNING id INTO v_result;

  IF v_result IS NULL THEN
    RAISE EXCEPTION '条目不存在或不属于你的企业' USING ERRCODE = '42501';
  END IF;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.upsert_enterprise_qa_faq(TEXT, TEXT, UUID, TEXT[], JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_enterprise_qa_faq(TEXT, TEXT, UUID, TEXT[], JSONB) TO authenticated;