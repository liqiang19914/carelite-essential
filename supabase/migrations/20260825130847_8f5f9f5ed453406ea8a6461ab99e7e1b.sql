-- RPC: 企业视角访客会话列表（管理员看全部/可按健管师筛选，员工只看自己）
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
  v_eid := public.get_profile_enterprise_id(v_caller);
  IF v_eid IS NULL THEN
    RAISE EXCEPTION 'no enterprise';
  END IF;
  v_is_admin := public.is_enterprise_admin(v_caller);

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
         OR s.visitor_name ILIKE '%' || v_q || '%'
         OR s.visitor_phone ILIKE '%' || v_q || '%');

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
           OR s.visitor_name ILIKE '%' || v_q || '%'
           OR s.visitor_phone ILIKE '%' || v_q || '%')
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

-- RPC: 企业视角会话详情（本人健管师或同企业管理员），带已标定消息清单
CREATE OR REPLACE FUNCTION public.get_enterprise_qa_session(p_session_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_eid UUID;
  v_session public.manager_public_qa_sessions%ROWTYPE;
  v_mgr_eid UUID;
  v_messages JSON;
  v_calibrated JSON;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
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