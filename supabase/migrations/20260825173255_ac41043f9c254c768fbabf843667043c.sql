CREATE OR REPLACE FUNCTION public.qa_session_upsert_and_log(
  p_manager_id UUID,
  p_visitor_token TEXT,
  p_visitor_user_id UUID,
  p_entry_source TEXT,
  p_context_type TEXT,
  p_context_id UUID,
  p_list_visible BOOLEAN,
  p_user_content TEXT
)
RETURNS TABLE (session_id UUID, prior_message_count INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sid UUID;
  v_prior INTEGER;
BEGIN
  IF p_manager_id IS NULL OR NULLIF(TRIM(p_visitor_token), '') IS NULL THEN
    RAISE EXCEPTION '缺少会话参数';
  END IF;

  INSERT INTO public.manager_public_qa_sessions (
    manager_id, visitor_token, visitor_user_id, entry_source,
    context_type, context_id, list_visible, first_message, message_count, last_active_at
  )
  VALUES (
    p_manager_id, p_visitor_token, p_visitor_user_id,
    COALESCE(p_entry_source, 'public_qa'),
    p_context_type, p_context_id, COALESCE(p_list_visible, TRUE),
    LEFT(COALESCE(p_user_content, ''), 200), 0, now()
  )
  ON CONFLICT (manager_id, visitor_token)
  DO UPDATE SET last_active_at = EXCLUDED.last_active_at
  RETURNING id, message_count INTO v_sid, v_prior;

  IF p_user_content IS NOT NULL AND TRIM(p_user_content) <> '' THEN
    INSERT INTO public.manager_public_qa_messages (session_id, role, content)
    VALUES (v_sid, 'user', p_user_content);
  END IF;

  RETURN QUERY SELECT v_sid, v_prior;
END;
$function$;

REVOKE ALL ON FUNCTION public.qa_session_upsert_and_log(UUID, TEXT, UUID, TEXT, TEXT, UUID, BOOLEAN, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.qa_session_upsert_and_log(UUID, TEXT, UUID, TEXT, TEXT, UUID, BOOLEAN, TEXT) FROM anon;
REVOKE ALL ON FUNCTION public.qa_session_upsert_and_log(UUID, TEXT, UUID, TEXT, TEXT, UUID, BOOLEAN, TEXT) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.qa_session_upsert_and_log(UUID, TEXT, UUID, TEXT, TEXT, UUID, BOOLEAN, TEXT) TO service_role;

CREATE OR REPLACE FUNCTION public.qa_session_log_assistant(
  p_session_id UUID,
  p_assistant_content TEXT,
  p_citations JSONB,
  p_course_card JSONB,
  p_media JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sid UUID;
  v_prior INTEGER;
BEGIN
  SELECT id, message_count INTO v_sid, v_prior
  FROM public.manager_public_qa_sessions
  WHERE id = p_session_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF p_assistant_content IS NOT NULL AND TRIM(p_assistant_content) <> '' THEN
    INSERT INTO public.manager_public_qa_messages (session_id, role, content, citations, course_card, media)
    VALUES (v_sid, 'assistant', p_assistant_content, p_citations, p_course_card, p_media);
  END IF;

  UPDATE public.manager_public_qa_sessions
  SET message_count = v_prior + 1,
      last_active_at = now()
  WHERE id = v_sid;
END;
$function$;

REVOKE ALL ON FUNCTION public.qa_session_log_assistant(UUID, TEXT, JSONB, JSONB, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.qa_session_log_assistant(UUID, TEXT, JSONB, JSONB, JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.qa_session_log_assistant(UUID, TEXT, JSONB, JSONB, JSONB) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.qa_session_log_assistant(UUID, TEXT, JSONB, JSONB, JSONB) TO service_role;

CREATE OR REPLACE FUNCTION public.qa_session_delete(
  p_session_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  DELETE FROM public.manager_public_qa_sessions WHERE id = p_session_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.qa_session_delete(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.qa_session_delete(UUID) FROM anon;
REVOKE ALL ON FUNCTION public.qa_session_delete(UUID) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.qa_session_delete(UUID) TO service_role;