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

  SELECT id INTO v_faq_id
  FROM public.enterprise_qa_faqs
  WHERE enterprise_id = v_mgr_eid
    AND source = 'calibration'
    AND question = v_q
  LIMIT 1
  FOR UPDATE;

  IF v_faq_id IS NOT NULL THEN
    UPDATE public.enterprise_qa_faqs
    SET answer = v_answer,
        source_message_id = p_message_id,
        updated_at = NOW()
    WHERE id = v_faq_id;
  ELSE
    INSERT INTO public.enterprise_qa_faqs (
      enterprise_id, question, answer, source, source_message_id, created_by
    )
    VALUES (v_mgr_eid, v_q, v_answer, 'calibration', p_message_id, v_caller)
    RETURNING id INTO v_faq_id;
  END IF;

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