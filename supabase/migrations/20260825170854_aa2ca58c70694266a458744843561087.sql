ALTER TABLE public.manager_public_qa_sessions
  ADD COLUMN IF NOT EXISTS visitor_user_id UUID,
  ADD COLUMN IF NOT EXISTS entry_source TEXT NOT NULL DEFAULT 'public_qa',
  ADD COLUMN IF NOT EXISTS context_type TEXT,
  ADD COLUMN IF NOT EXISTS context_id UUID,
  ADD COLUMN IF NOT EXISTS list_visible BOOLEAN NOT NULL DEFAULT TRUE;

CREATE INDEX IF NOT EXISTS mqa_sessions_visitor_user_idx
  ON public.manager_public_qa_sessions (visitor_user_id, manager_id);
CREATE INDEX IF NOT EXISTS mqa_sessions_list_cursor_idx
  ON public.manager_public_qa_sessions (last_active_at DESC, id DESC);

ALTER TABLE public.manager_public_qa_messages
  ADD COLUMN IF NOT EXISTS media JSONB;

ALTER TABLE public.enterprise_qa_faqs
  ADD COLUMN IF NOT EXISTS media JSONB;

ALTER TABLE public.merchant_consult_settings
  ADD COLUMN IF NOT EXISTS ai_image_generation_enabled BOOLEAN NOT NULL DEFAULT FALSE;

CREATE OR REPLACE FUNCTION public.list_my_manager_qa_sessions(
  p_manager_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_disabled BOOLEAN;
  v_items JSON;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION '未登录';
  END IF;
  SELECT p.is_disabled INTO v_disabled FROM public.profiles p WHERE p.id = v_caller;
  IF NOT FOUND OR COALESCE(v_disabled, false) THEN
    RAISE EXCEPTION '账号已停用' USING ERRCODE = '42501';
  END IF;

  SELECT json_agg(t ORDER BY t.last_active_at DESC, t.id DESC) INTO v_items
  FROM (
    SELECT
      s.id,
      s.first_message AS title,
      s.message_count,
      s.last_active_at,
      s.created_at,
      s.entry_source,
      s.list_visible
    FROM public.manager_public_qa_sessions s
    WHERE s.manager_id = p_manager_id
      AND s.visitor_user_id = v_caller
    LIMIT 50
  ) t;

  RETURN COALESCE(v_items, '[]'::JSON);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_my_manager_qa_sessions(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_manager_qa_sessions(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_my_manager_qa_sessions(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_my_manager_qa_messages(
  p_session_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_disabled BOOLEAN;
  v_session public.manager_public_qa_sessions%ROWTYPE;
  v_messages JSON;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION '未登录';
  END IF;
  SELECT p.is_disabled INTO v_disabled FROM public.profiles p WHERE p.id = v_caller;
  IF NOT FOUND OR COALESCE(v_disabled, false) THEN
    RAISE EXCEPTION '账号已停用' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_session
  FROM public.manager_public_qa_sessions s
  WHERE s.id = p_session_id
    AND s.visitor_user_id = v_caller;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT json_agg(t ORDER BY t.created_at) INTO v_messages
  FROM (
    SELECT
      m.id,
      m.role,
      m.content,
      m.citations,
      m.course_card,
      m.media,
      m.created_at
    FROM public.manager_public_qa_messages m
    WHERE m.session_id = p_session_id
  ) t;

  RETURN json_build_object(
    'session', json_build_object(
      'id', v_session.id,
      'manager_id', v_session.manager_id,
      'first_message', v_session.first_message,
      'message_count', v_session.message_count,
      'last_active_at', v_session.last_active_at,
      'created_at', v_session.created_at,
      'entry_source', v_session.entry_source
    ),
    'messages', COALESCE(v_messages, '[]'::JSON)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_my_manager_qa_messages(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_manager_qa_messages(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_manager_qa_messages(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.delete_my_manager_qa_session(
  p_session_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_disabled BOOLEAN;
  v_owner UUID;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION '未登录';
  END IF;
  SELECT p.is_disabled INTO v_disabled FROM public.profiles p WHERE p.id = v_caller;
  IF NOT FOUND OR COALESCE(v_disabled, false) THEN
    RAISE EXCEPTION '账号已停用' USING ERRCODE = '42501';
  END IF;

  SELECT s.visitor_user_id INTO v_owner
  FROM public.manager_public_qa_sessions s
  WHERE s.id = p_session_id;
  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;
  IF v_owner IS DISTINCT FROM v_caller THEN
    RAISE EXCEPTION '无权删除该会话' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.manager_public_qa_sessions s WHERE s.id = p_session_id;
  RETURN TRUE;
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_my_manager_qa_session(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_my_manager_qa_session(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_my_manager_qa_session(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.list_enterprise_qa_sessions(
  p_manager_id UUID DEFAULT NULL,
  p_query TEXT DEFAULT NULL,
  p_lead_filter TEXT DEFAULT 'all',
  p_limit INTEGER DEFAULT 20,
  p_offset INTEGER DEFAULT 0,
  p_cursor_last_active_at TIMESTAMPTZ DEFAULT NULL,
  p_cursor_id UUID DEFAULT NULL
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
  v_cursor_ts TIMESTAMPTZ := p_cursor_last_active_at;
  v_cursor_id UUID := p_cursor_id;
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

  IF v_cursor_ts IS NULL OR v_cursor_id IS NULL THEN
    v_cursor_ts := NULL;
    v_cursor_id := NULL;
  END IF;

  SELECT COUNT(*), COUNT(*) FILTER (WHERE COALESCE(s.visitor_phone, vp.phone) IS NOT NULL)
    INTO v_total, v_with_phone
  FROM public.manager_public_qa_sessions s
  LEFT JOIN public.profiles vp ON vp.id = s.visitor_user_id
  WHERE s.list_visible
    AND (
      (v_scope_manager IS NOT NULL AND s.manager_id = v_scope_manager)
      OR (v_is_admin AND v_scope_manager IS NULL
          AND public.get_profile_enterprise_id(s.manager_id) = v_eid)
    )
    AND (v_lead = 'all'
         OR (v_lead = 'has_phone' AND COALESCE(s.visitor_phone, vp.phone) IS NOT NULL)
         OR (v_lead = 'anonymous' AND COALESCE(s.visitor_phone, vp.phone) IS NULL))
    AND (v_q IS NULL
         OR s.visitor_name ILIKE '%' || v_q || '%' ESCAPE '\'
         OR s.visitor_phone ILIKE '%' || v_q || '%' ESCAPE '\'
         OR COALESCE(vp.nickname, '') ILIKE '%' || v_q || '%' ESCAPE '\'
         OR COALESCE(vp.phone, '') ILIKE '%' || v_q || '%' ESCAPE '\');

  SELECT json_agg(t ORDER BY t.last_active_at DESC, t.id DESC) INTO v_items
  FROM (
    SELECT
      s.id,
      s.visitor_token,
      s.visitor_user_id,
      s.entry_source,
      s.context_type,
      s.context_id,
      COALESCE(s.visitor_phone, vp.phone) AS visitor_phone,
      COALESCE(s.visitor_name, vp.nickname) AS visitor_name,
      s.first_message,
      s.message_count,
      s.last_active_at,
      s.created_at,
      s.manager_id,
      (s.visitor_user_id IS NOT NULL) AS is_logged_in,
      COALESCE(m.partner_card_display_name, p.nickname, '健管师') AS manager_name
    FROM public.manager_public_qa_sessions s
    LEFT JOIN public.managers m ON m.id = s.manager_id
    LEFT JOIN public.profiles p ON p.id = s.manager_id
    LEFT JOIN public.profiles vp ON vp.id = s.visitor_user_id
    WHERE s.list_visible
      AND (
        (v_scope_manager IS NOT NULL AND s.manager_id = v_scope_manager)
        OR (v_is_admin AND v_scope_manager IS NULL
            AND public.get_profile_enterprise_id(s.manager_id) = v_eid)
      )
      AND (v_lead = 'all'
           OR (v_lead = 'has_phone' AND COALESCE(s.visitor_phone, vp.phone) IS NOT NULL)
           OR (v_lead = 'anonymous' AND COALESCE(s.visitor_phone, vp.phone) IS NULL))
      AND (v_q IS NULL
           OR s.visitor_name ILIKE '%' || v_q || '%' ESCAPE '\'
           OR s.visitor_phone ILIKE '%' || v_q || '%' ESCAPE '\'
           OR COALESCE(vp.nickname, '') ILIKE '%' || v_q || '%' ESCAPE '\'
           OR COALESCE(vp.phone, '') ILIKE '%' || v_q || '%' ESCAPE '\')
      AND (v_cursor_ts IS NULL
           OR (s.last_active_at < v_cursor_ts
               OR (s.last_active_at = v_cursor_ts AND s.id < v_cursor_id)))
    LIMIT GREATEST(LEAST(p_limit, 100), 1)
    OFFSET CASE WHEN v_cursor_ts IS NULL THEN GREATEST(p_offset, 0) ELSE 0 END
  ) t;

  RETURN json_build_object(
    'items', COALESCE(v_items, '[]'::JSON),
    'total', v_total,
    'with_phone_count', v_with_phone
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_qa_sessions(UUID, TEXT, TEXT, INTEGER, INTEGER, TIMESTAMPTZ, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_enterprise_qa_sessions(UUID, TEXT, TEXT, INTEGER, INTEGER, TIMESTAMPTZ, UUID) TO authenticated;

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
  v_visitor_name TEXT;
  v_visitor_phone TEXT;
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

  IF v_session.visitor_user_id IS NOT NULL THEN
    SELECT p.nickname, p.phone INTO v_visitor_name, v_visitor_phone
    FROM public.profiles p WHERE p.id = v_session.visitor_user_id;
  END IF;

  SELECT json_agg(t ORDER BY t.created_at) INTO v_messages
  FROM (
    SELECT
      m.id,
      m.role,
      m.content,
      m.citations,
      m.course_card,
      m.media,
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
      'visitor_user_id', v_session.visitor_user_id,
      'visitor_phone', COALESCE(v_session.visitor_phone, v_visitor_phone),
      'visitor_name', COALESCE(v_session.visitor_name, v_visitor_name),
      'entry_source', v_session.entry_source,
      'context_type', v_session.context_type,
      'context_id', v_session.context_id,
      'is_logged_in', (v_session.visitor_user_id IS NOT NULL),
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