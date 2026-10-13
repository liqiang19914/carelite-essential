-- 标定来源 FAQ 的唯一性（企业+问题精确串），消除并发标定的重复条目
CREATE UNIQUE INDEX IF NOT EXISTS uq_enterprise_qa_faqs_calibration
  ON public.enterprise_qa_faqs (enterprise_id, question)
  WHERE source = 'calibration';

-- ─── upsert：修跨企业覆盖漏洞（冲突更新必须落在调用者自己的企业），并校验账号状态 ───
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
  v_actor RECORD;
  v_eid UUID;
  v_kw TEXT[];
  v_result UUID;
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
  WHERE public.enterprise_qa_faqs.enterprise_id = v_eid
  RETURNING id INTO v_result;

  IF v_result IS NULL THEN
    RAISE EXCEPTION '条目不存在或不属于你的企业' USING ERRCODE = '42501';
  END IF;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.upsert_enterprise_qa_faq(TEXT, TEXT, UUID, TEXT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_enterprise_qa_faq(TEXT, TEXT, UUID, TEXT[]) TO authenticated;

-- ─── calibrate：标定 FAQ 改为原子 upsert（配合唯一索引），并校验账号状态 ───
CREATE OR REPLACE FUNCTION public.calibrate_qa_answer(
  p_message_id UUID,
  p_correct_answer TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_actor RECORD;
  v_msg public.manager_public_qa_messages;
  v_session public.manager_public_qa_sessions;
  v_mgr_eid UUID;
  v_caller_eid UUID;
  v_q TEXT;
  v_faq_id UUID;
  v_answer TEXT;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  SELECT p.role, p.is_disabled INTO v_actor FROM public.profiles p WHERE p.id = v_caller;
  IF NOT FOUND OR v_actor.role IS DISTINCT FROM 'manager' OR COALESCE(v_actor.is_disabled, false) THEN
    RAISE EXCEPTION '账号已停用或无权访问' USING ERRCODE = '42501';
  END IF;
  v_answer := NULLIF(TRIM(p_correct_answer), '');
  IF v_answer IS NULL THEN
    RAISE EXCEPTION '正确答案不能为空' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_msg
  FROM public.manager_public_qa_messages
  WHERE id = p_message_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '消息不存在' USING ERRCODE = '22023';
  END IF;
  IF v_msg.role IS DISTINCT FROM 'assistant' THEN
    RAISE EXCEPTION '只能对 AI 回答进行标定' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_session
  FROM public.manager_public_qa_sessions
  WHERE id = v_msg.session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '会话不存在' USING ERRCODE = '22023';
  END IF;

  v_mgr_eid := public.get_profile_enterprise_id(v_session.manager_id);
  v_caller_eid := public.get_profile_enterprise_id(v_caller);
  IF v_session.manager_id IS DISTINCT FROM v_caller
     AND NOT (v_caller_eid IS NOT NULL
              AND v_caller_eid = v_mgr_eid
              AND public.is_enterprise_admin(v_caller)) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF v_mgr_eid IS NULL THEN
    RAISE EXCEPTION '该健管师没有企业归属，无法沉淀标准问答' USING ERRCODE = '22023';
  END IF;

  SELECT content INTO v_q
  FROM public.manager_public_qa_messages
  WHERE session_id = v_msg.session_id
    AND role = 'user'
    AND created_at <= v_msg.created_at
  ORDER BY created_at DESC
  LIMIT 1;
  IF v_q IS NULL THEN
    v_q := COALESCE(NULLIF(TRIM(v_session.first_message), ''), '（无原文问题）');
  END IF;

  INSERT INTO public.enterprise_qa_faqs (
    enterprise_id, question, answer, source, source_message_id, created_by
  )
  VALUES (v_mgr_eid, v_q, v_answer, 'calibration', p_message_id, v_caller)
  ON CONFLICT (enterprise_id, question) WHERE source = 'calibration'
  DO UPDATE SET answer = EXCLUDED.answer,
                source_message_id = EXCLUDED.source_message_id,
                updated_at = NOW()
  RETURNING id INTO v_faq_id;

  INSERT INTO public.enterprise_qa_calibrations (
    enterprise_id, session_id, message_id, manager_id, question, ai_answer, correct_answer, faq_id, created_by
  )
  VALUES (
    v_mgr_eid, v_msg.session_id, p_message_id, v_session.manager_id, v_q, v_msg.content, v_answer, v_faq_id, v_caller
  )
  ON CONFLICT (message_id) DO UPDATE
  SET correct_answer = EXCLUDED.correct_answer,
      faq_id = EXCLUDED.faq_id,
      created_by = EXCLUDED.created_by;

  RETURN jsonb_build_object(
    'faq_id', v_faq_id,
    'question', v_q
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.calibrate_qa_answer(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.calibrate_qa_answer(UUID, TEXT) TO authenticated;

-- ─── delete：校验账号状态 ───
CREATE OR REPLACE FUNCTION public.delete_enterprise_qa_faq(p_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_actor RECORD;
  v_eid UUID;
  v_faq public.enterprise_qa_faqs;
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

-- ─── batch_import：严格类型/长度校验（整批拒绝），并校验账号状态 ───
CREATE OR REPLACE FUNCTION public.batch_import_enterprise_qa_faqs(p_items JSONB)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_actor RECORD;
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
  SELECT p.role, p.is_disabled INTO v_actor FROM public.profiles p WHERE p.id = v_caller;
  IF NOT FOUND OR v_actor.role IS DISTINCT FROM 'manager' OR COALESCE(v_actor.is_disabled, false) THEN
    RAISE EXCEPTION '账号已停用或无权访问' USING ERRCODE = '42501';
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
    IF jsonb_typeof(v_item) <> 'object' THEN
      RAISE EXCEPTION '条目格式无效：每条必须是「问题+答案」对象' USING ERRCODE = '22023';
    END IF;
    IF (v_item ? 'question' AND jsonb_typeof(v_item->'question') <> 'string')
       OR (v_item ? 'answer' AND jsonb_typeof(v_item->'answer') <> 'string') THEN
      RAISE EXCEPTION '条目格式无效：问题与答案必须是文字' USING ERRCODE = '22023';
    END IF;
    IF (v_item ? 'keywords') AND jsonb_typeof(v_item->'keywords') <> 'array' THEN
      RAISE EXCEPTION '条目格式无效：关键词必须是文字列表' USING ERRCODE = '22023';
    END IF;

    v_q := NULLIF(TRIM(COALESCE(v_item->>'question', '')), '');
    v_a := NULLIF(TRIM(COALESCE(v_item->>'answer', '')), '');
    IF v_q IS NULL OR v_a IS NULL THEN
      RAISE EXCEPTION '条目格式无效：问题与答案均不能为空' USING ERRCODE = '22023';
    END IF;
    IF char_length(v_q) > 1000 OR char_length(v_a) > 5000 THEN
      RAISE EXCEPTION '条目过长' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements_text(COALESCE(v_item->'keywords', '[]'::JSONB)) kw
      WHERE char_length(btrim(kw)) > 50
    ) THEN
      RAISE EXCEPTION '关键词过长（单个不超过 50 字）' USING ERRCODE = '22023';
    END IF;

    SELECT ARRAY(
      SELECT btrim(kw)
      FROM jsonb_array_elements_text(COALESCE(v_item->'keywords', '[]'::JSONB)) kw
      WHERE btrim(kw) <> ''
    ) INTO v_kw;
    IF array_length(v_kw, 1) IS NOT NULL AND array_length(v_kw, 1) > 10 THEN
      RAISE EXCEPTION '关键词过多（每条最多 10 个）' USING ERRCODE = '22023';
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

-- ─── list_enterprise_qa_sessions：账号校验 + 搜索通配符转义 ───
CREATE OR REPLACE FUNCTION public.list_enterprise_qa_sessions(
  p_manager_id UUID DEFAULT NULL,
  p_query TEXT DEFAULT NULL,
  p_lead_filter TEXT DEFAULT 'all',
  p_limit INTEGER DEFAULT 20,
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
  v_is_admin BOOLEAN;
  v_scope_manager UUID;
  v_items JSON;
  v_total INTEGER;
  v_with_phone INTEGER;
  v_q TEXT := NULLIF(TRIM(p_query), '');
  v_lead TEXT := COALESCE(p_lead_filter, 'all');
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
  v_is_admin := public.is_enterprise_admin(v_caller);
  IF v_q IS NOT NULL THEN
    v_q := REPLACE(REPLACE(REPLACE(v_q, '\', '\\'), '%', '\%'), '_', '\_');
  END IF;

  IF v_is_admin THEN
    IF p_manager_id IS NOT NULL THEN
      IF public.get_profile_enterprise_id(p_manager_id) IS DISTINCT FROM v_eid THEN
        RAISE EXCEPTION 'forbidden';
      END IF;
      v_scope_manager := p_manager_id;
    END IF;
  ELSE
    v_scope_manager := v_caller;
  END IF;

  SELECT COUNT(*), COUNT(*) FILTER (WHERE s.visitor_phone IS NOT NULL)
    INTO v_total, v_with_phone
  FROM public.manager_public_qa_sessions s
  WHERE (
      (v_scope_manager IS NOT NULL AND s.manager_id = v_scope_manager)
      OR (v_is_admin AND v_scope_manager IS NULL
          AND public.get_profile_enterprise_id(s.manager_id) = v_eid)
    )
    AND (v_lead = 'all'
         OR (v_lead = 'has_phone' AND s.visitor_phone IS NOT NULL)
         OR (v_lead = 'anonymous' AND s.visitor_phone IS NULL))
    AND (v_q IS NULL
         OR s.visitor_name ILIKE '%' || v_q || '%' ESCAPE '\'
         OR s.visitor_phone ILIKE '%' || v_q || '%' ESCAPE '\');

  SELECT json_agg(t) INTO v_items
  FROM (
    SELECT
      s.id,
      s.visitor_token,
      s.visitor_phone,
      s.visitor_name,
      s.first_message,
      s.message_count,
      s.last_active_at,
      s.created_at,
      s.manager_id,
      COALESCE(m.partner_card_display_name, p.nickname, '健管师') AS manager_name
    FROM public.manager_public_qa_sessions s
    LEFT JOIN public.managers m ON m.id = s.manager_id
    LEFT JOIN public.profiles p ON p.id = s.manager_id
    WHERE (
        (v_scope_manager IS NOT NULL AND s.manager_id = v_scope_manager)
        OR (v_is_admin AND v_scope_manager IS NULL
            AND public.get_profile_enterprise_id(s.manager_id) = v_eid)
      )
      AND (v_lead = 'all'
           OR (v_lead = 'has_phone' AND s.visitor_phone IS NOT NULL)
           OR (v_lead = 'anonymous' AND s.visitor_phone IS NULL))
      AND (v_q IS NULL
           OR s.visitor_name ILIKE '%' || v_q || '%' ESCAPE '\'
           OR s.visitor_phone ILIKE '%' || v_q || '%' ESCAPE '\')
    ORDER BY s.last_active_at DESC
    LIMIT GREATEST(LEAST(p_limit, 100), 1)
    OFFSET GREATEST(p_offset, 0)
  ) t;

  RETURN json_build_object(
    'items', COALESCE(v_items, '[]'::JSON),
    'total', v_total,
    'with_phone_count', v_with_phone
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_qa_sessions(UUID, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_enterprise_qa_sessions(UUID, TEXT, TEXT, INTEGER, INTEGER) TO authenticated;

-- ─── get_enterprise_qa_session：账号校验 ───
CREATE OR REPLACE FUNCTION public.get_enterprise_qa_session(p_session_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_actor RECORD;
  v_eid UUID;
  v_session public.manager_public_qa_sessions%ROWTYPE;
  v_mgr_eid UUID;
  v_messages JSON;
  v_calibrated JSON;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  SELECT p.role, p.is_disabled INTO v_actor FROM public.profiles p WHERE p.id = v_caller;
  IF NOT FOUND OR v_actor.role IS DISTINCT FROM 'manager' OR COALESCE(v_actor.is_disabled, false) THEN
    RAISE EXCEPTION '账号已停用或无权访问' USING ERRCODE = '42501';
  END IF;
  v_eid := public.get_profile_enterprise_id(v_caller);

  SELECT * INTO v_session
  FROM public.manager_public_qa_sessions
  WHERE id = p_session_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_mgr_eid := public.get_profile_enterprise_id(v_session.manager_id);
  IF v_session.manager_id <> v_caller THEN
    IF v_eid IS NULL OR v_mgr_eid IS DISTINCT FROM v_eid
       OR NOT public.is_enterprise_admin(v_caller) THEN
      RAISE EXCEPTION 'forbidden';
    END IF;
  END IF;

  SELECT json_agg(t ORDER BY t.created_at) INTO v_messages
  FROM (
    SELECT
      m.id,
      m.role,
      m.content,
      m.citations,
      m.created_at
    FROM public.manager_public_qa_messages m
    WHERE m.session_id = p_session_id
  ) t;

  SELECT COALESCE(json_agg(c.message_id), '[]'::JSON) INTO v_calibrated
  FROM public.enterprise_qa_calibrations c
  WHERE c.session_id = p_session_id;

  RETURN json_build_object(
    'session', json_build_object(
      'id', v_session.id,
      'manager_id', v_session.manager_id,
      'visitor_token', v_session.visitor_token,
      'visitor_phone', v_session.visitor_phone,
      'visitor_name', v_session.visitor_name,
      'first_message', v_session.first_message,
      'message_count', v_session.message_count,
      'last_active_at', v_session.last_active_at,
      'created_at', v_session.created_at
    ),
    'messages', COALESCE(v_messages, '[]'::JSON),
    'calibrated_message_ids', v_calibrated
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_enterprise_qa_session(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_enterprise_qa_session(UUID) TO authenticated;

-- ─── list_enterprise_qa_faqs：账号校验 + 搜索通配符转义 ───
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

-- ─── match：收回普通登录用户的执行权，仅服务端可调用（堵跨企业读取） ───
REVOKE ALL ON FUNCTION public.match_enterprise_qa_faqs(UUID, TEXT, INTEGER) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.match_enterprise_qa_faqs(UUID, TEXT, INTEGER) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.match_enterprise_qa_faqs(UUID, TEXT, INTEGER) TO service_role;