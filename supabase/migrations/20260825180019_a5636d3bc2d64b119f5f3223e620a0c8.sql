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
      q.media,
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
  v_actor RECORD;
  v_eid UUID;
  v_items JSON;
  v_total INTEGER;
  v_q TEXT := NULLIF(TRIM(p_query), '');
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
  IF v_q IS NOT NULL THEN
    v_q := REPLACE(REPLACE(REPLACE(v_q, '\', '\\'), '%', '\%'), '_', '\_');
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM public.enterprise_qa_faqs q
  WHERE q.enterprise_id = v_eid
    AND (v_q IS NULL
         OR q.question ILIKE '%' || v_q || '%' ESCAPE '\'
         OR q.answer ILIKE '%' || v_q || '%' ESCAPE '\'
         OR EXISTS (
              SELECT 1 FROM unnest(q.keywords) kw
              WHERE btrim(kw) <> '' AND btrim(kw) ILIKE '%' || v_q || '%' ESCAPE '\'
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
      q.media,
      q.created_at,
      q.updated_at
    FROM public.enterprise_qa_faqs q
    WHERE q.enterprise_id = v_eid
      AND (v_q IS NULL
           OR q.question ILIKE '%' || v_q || '%' ESCAPE '\'
           OR q.answer ILIKE '%' || v_q || '%' ESCAPE '\'
           OR EXISTS (
                SELECT 1 FROM unnest(q.keywords) kw
                WHERE btrim(kw) <> '' AND btrim(kw) ILIKE '%' || v_q || '%' ESCAPE '\'
              ))
    ORDER BY q.updated_at DESC, q.id DESC
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
      IF v_item_type NOT IN ('image','video') THEN
        RAISE EXCEPTION '素材类型不正确' USING ERRCODE = '22023';
      END IF;
      IF v_item_url IS NULL OR v_item_url !~ '^https://[^/]+\.aliyuncs\.com/' THEN
        RAISE EXCEPTION '素材地址不正确' USING ERRCODE = '22023';
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

DROP FUNCTION IF EXISTS public.upsert_enterprise_qa_faq(TEXT, TEXT, UUID, TEXT[]);

DROP FUNCTION IF EXISTS public.save_merchant_consult_settings(TEXT[], UUID, BOOLEAN, TEXT, TEXT, BOOLEAN);
DROP FUNCTION IF EXISTS public.save_merchant_consult_settings(TEXT[], UUID, BOOLEAN, TEXT, TEXT, BOOLEAN, TEXT, TEXT, BOOLEAN);

CREATE OR REPLACE FUNCTION public.save_merchant_consult_settings(
  p_channels TEXT[],
  p_ai_manager_id UUID,
  p_human_handoff_enabled BOOLEAN,
  p_wecom_qr_url TEXT,
  p_wecom_acquisition_url TEXT,
  p_miniapp_contact_enabled BOOLEAN,
  p_wecom_kf_url TEXT,
  p_wecom_kf_corp_id TEXT,
  p_wecom_kf_enabled BOOLEAN,
  p_ai_image_generation_enabled BOOLEAN
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_channel TEXT;
  v_ok BOOLEAN;
  v_kf_url TEXT;
  v_kf_corp TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '只有商户账号可以配置咨询方式' USING ERRCODE = '42501';
  END IF;

  v_ok := true;
  IF p_channels IS NOT NULL THEN
    FOREACH v_channel IN ARRAY p_channels LOOP
      IF v_channel NOT IN ('ai','miniapp_contact','wecom_qr','wecom_acquisition','wecom_kf') THEN
        v_ok := false;
      END IF;
    END LOOP;
  END IF;
  IF NOT v_ok THEN
    RAISE EXCEPTION '咨询方式配置不合法' USING ERRCODE = '22023';
  END IF;

  IF p_ai_manager_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.managers m
      WHERE m.id = p_ai_manager_id
        AND public.get_enterprise_root_manager_id(m.id) = v_root
    ) THEN
      RAISE EXCEPTION '只能选择本企业的健管师来回答商城咨询' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF char_length(COALESCE(p_wecom_qr_url, '')) > 2000 THEN
    RAISE EXCEPTION '企微二维码链接过长' USING ERRCODE = '22023';
  END IF;
  IF char_length(COALESCE(p_wecom_acquisition_url, '')) > 2000 THEN
    RAISE EXCEPTION '获客助手链接过长' USING ERRCODE = '22023';
  END IF;

  v_kf_url := btrim(COALESCE(p_wecom_kf_url, ''));
  v_kf_corp := btrim(COALESCE(p_wecom_kf_corp_id, ''));
  IF char_length(v_kf_url) > 2000 THEN
    RAISE EXCEPTION '微信客服链接过长' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_kf_corp) > 64 THEN
    RAISE EXCEPTION '企业 ID 过长' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(p_wecom_kf_enabled, false) THEN
    IF v_kf_url = '' OR v_kf_corp = '' THEN
      RAISE EXCEPTION '启用微信客服前请填写客服链接和企业 ID' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF v_kf_url <> '' AND v_kf_url NOT LIKE 'https://work.weixin.qq.com/kfid/%' THEN
    RAISE EXCEPTION '微信客服链接格式不正确' USING ERRCODE = '22023';
  END IF;
  IF v_kf_corp <> '' AND v_kf_corp !~ '^ww[0-9a-zA-Z_-]{6,64}$' THEN
    RAISE EXCEPTION '企业 ID 格式不正确（应为 ww 开头的企业微信企业 ID）' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.merchant_consult_settings (
    root_manager_id, channels, ai_manager_id, human_handoff_enabled,
    wecom_qr_url, wecom_acquisition_url, miniapp_contact_enabled,
    wecom_kf_url, wecom_kf_corp_id, wecom_kf_enabled, ai_image_generation_enabled
  ) VALUES (
    v_root, COALESCE(p_channels, '{}'), p_ai_manager_id,
    COALESCE(p_human_handoff_enabled, false),
    btrim(COALESCE(p_wecom_qr_url, '')), btrim(COALESCE(p_wecom_acquisition_url, '')),
    COALESCE(p_miniapp_contact_enabled, false),
    v_kf_url, v_kf_corp, COALESCE(p_wecom_kf_enabled, false),
    COALESCE(p_ai_image_generation_enabled, false)
  )
  ON CONFLICT (root_manager_id) DO UPDATE SET
    channels = COALESCE(EXCLUDED.channels, merchant_consult_settings.channels),
    ai_manager_id = CASE WHEN p_ai_manager_id IS NULL THEN merchant_consult_settings.ai_manager_id ELSE EXCLUDED.ai_manager_id END,
    human_handoff_enabled = COALESCE(EXCLUDED.human_handoff_enabled, false),
    wecom_qr_url = CASE WHEN p_wecom_qr_url IS NULL THEN merchant_consult_settings.wecom_qr_url ELSE EXCLUDED.wecom_qr_url END,
    wecom_acquisition_url = CASE WHEN p_wecom_acquisition_url IS NULL THEN merchant_consult_settings.wecom_acquisition_url ELSE EXCLUDED.wecom_acquisition_url END,
    miniapp_contact_enabled = COALESCE(EXCLUDED.miniapp_contact_enabled, false),
    wecom_kf_url = EXCLUDED.wecom_kf_url,
    wecom_kf_corp_id = EXCLUDED.wecom_kf_corp_id,
    wecom_kf_enabled = EXCLUDED.wecom_kf_enabled,
    ai_image_generation_enabled = COALESCE(EXCLUDED.ai_image_generation_enabled, false),
    updated_at = now();

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.save_merchant_consult_settings(TEXT[], UUID, BOOLEAN, TEXT, TEXT, BOOLEAN, TEXT, TEXT, BOOLEAN, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_merchant_consult_settings(TEXT[], UUID, BOOLEAN, TEXT, TEXT, BOOLEAN, TEXT, TEXT, BOOLEAN, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_merchant_consult_settings()
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_row public.merchant_consult_settings%ROWTYPE;
  v_ai_name TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_row FROM public.merchant_consult_settings WHERE root_manager_id = v_root;
  IF NOT FOUND THEN
    RETURN json_build_object('configured', false);
  END IF;

  SELECT m.partner_card_display_name INTO v_ai_name
  FROM public.managers m WHERE m.id = v_row.ai_manager_id;

  RETURN json_build_object(
    'configured', true,
    'channels', v_row.channels,
    'ai_manager_id', v_row.ai_manager_id,
    'ai_manager_name', COALESCE(v_ai_name, ''),
    'human_handoff_enabled', v_row.human_handoff_enabled,
    'wecom_qr_url', v_row.wecom_qr_url,
    'wecom_acquisition_url', v_row.wecom_acquisition_url,
    'miniapp_contact_enabled', v_row.miniapp_contact_enabled,
    'wecom_kf_url', v_row.wecom_kf_url,
    'wecom_kf_corp_id', v_row.wecom_kf_corp_id,
    'wecom_kf_enabled', v_row.wecom_kf_enabled,
    'ai_image_generation_enabled', v_row.ai_image_generation_enabled,
    'updated_at', v_row.updated_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_merchant_consult_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_merchant_consult_settings() TO authenticated;