-- ============================================
-- 公开问答 V1: 数据层
-- ============================================

-- 1. managers 表加 3 个公开问答字段
ALTER TABLE public.managers
  ADD COLUMN IF NOT EXISTS public_qa_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS public_qa_welcome_message TEXT,
  ADD COLUMN IF NOT EXISTS public_qa_lead_capture_mode TEXT NOT NULL DEFAULT 'both';

ALTER TABLE public.managers
  DROP CONSTRAINT IF EXISTS managers_public_qa_lead_capture_mode_check;
ALTER TABLE public.managers
  ADD CONSTRAINT managers_public_qa_lead_capture_mode_check
  CHECK (public_qa_lead_capture_mode IN ('none','card_after_3_turns','ai_natural','both'));

-- 2. 访客会话表
CREATE TABLE IF NOT EXISTS public.manager_public_qa_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  manager_id UUID NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  visitor_token TEXT NOT NULL,
  visitor_ip_hash TEXT,
  visitor_phone TEXT,
  visitor_name TEXT,
  first_message TEXT,
  message_count INTEGER NOT NULL DEFAULT 0,
  last_active_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT manager_public_qa_sessions_uniq UNIQUE (manager_id, visitor_token)
);

CREATE INDEX IF NOT EXISTS idx_pqa_sessions_manager_recent
  ON public.manager_public_qa_sessions (manager_id, last_active_at DESC);

CREATE INDEX IF NOT EXISTS idx_pqa_sessions_ip_recent
  ON public.manager_public_qa_sessions (visitor_ip_hash, last_active_at DESC);

-- 3. 访客消息表
CREATE TABLE IF NOT EXISTS public.manager_public_qa_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES public.manager_public_qa_sessions(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('user','assistant')),
  content TEXT NOT NULL,
  citations JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_pqa_messages_session_time
  ON public.manager_public_qa_messages (session_id, created_at);

CREATE INDEX IF NOT EXISTS idx_pqa_messages_created
  ON public.manager_public_qa_messages (created_at);

-- 4. RLS 启用
ALTER TABLE public.manager_public_qa_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manager_public_qa_messages ENABLE ROW LEVEL SECURITY;

-- 5. RLS 策略 - 管理师本人 SELECT 自己的会话与消息（EF 走 service_role 跳过 RLS）
DROP POLICY IF EXISTS "Manager can read own qa sessions" ON public.manager_public_qa_sessions;
CREATE POLICY "Manager can read own qa sessions"
  ON public.manager_public_qa_sessions
  FOR SELECT
  USING (manager_id = auth.uid());

DROP POLICY IF EXISTS "Manager can read own qa messages" ON public.manager_public_qa_messages;
CREATE POLICY "Manager can read own qa messages"
  ON public.manager_public_qa_messages
  FOR SELECT
  USING (session_id IN (
    SELECT id FROM public.manager_public_qa_sessions WHERE manager_id = auth.uid()
  ));

-- 6. RPC: get_public_qa_config (anon 可调，读取公开配置；不含敏感字段)
CREATE OR REPLACE FUNCTION public.get_public_qa_config(p_manager_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_manager managers%ROWTYPE;
  v_profile profiles%ROWTYPE;
BEGIN
  IF p_manager_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_manager FROM managers WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_profile FROM profiles WHERE id = p_manager_id;

  RETURN json_build_object(
    'manager_id', v_manager.id,
    'enabled', COALESCE(v_manager.public_qa_enabled, false),
    'welcome_message', v_manager.public_qa_welcome_message,
    'lead_capture_mode', COALESCE(v_manager.public_qa_lead_capture_mode, 'both'),
    'display_name', COALESCE(v_manager.partner_card_display_name, v_profile.nickname, '健康管理师'),
    'avatar_url', COALESCE(v_manager.digital_avatar_image_url, v_manager.partner_card_avatar_url, v_profile.avatar_url),
    'tagline', v_manager.tagline,
    'is_example', COALESCE(v_manager.is_example, false),
    'knowledge_index_status', COALESCE(v_manager.knowledge_index_status, 'none')
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_public_qa_config(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_qa_config(UUID) TO anon, authenticated;

-- 7. RPC: submit_public_qa_lead (anon 可调，留资；只能从 NULL → 非 NULL)
CREATE OR REPLACE FUNCTION public.submit_public_qa_lead(
  p_manager_id UUID,
  p_visitor_token TEXT,
  p_phone TEXT,
  p_name TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_session manager_public_qa_sessions%ROWTYPE;
BEGIN
  IF p_manager_id IS NULL OR p_visitor_token IS NULL OR p_phone IS NULL THEN
    RAISE EXCEPTION 'params missing';
  END IF;

  IF p_phone !~ '^1[3-9][0-9]{9}$' THEN
    RAISE EXCEPTION 'invalid phone';
  END IF;

  SELECT * INTO v_session
  FROM manager_public_qa_sessions
  WHERE manager_id = p_manager_id AND visitor_token = p_visitor_token;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'session not found';
  END IF;

  IF v_session.visitor_phone IS NOT NULL THEN
    RAISE EXCEPTION 'lead already submitted';
  END IF;

  UPDATE manager_public_qa_sessions
  SET visitor_phone = p_phone,
      visitor_name = COALESCE(NULLIF(TRIM(p_name), ''), visitor_name),
      last_active_at = NOW()
  WHERE id = v_session.id;

  RETURN json_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_public_qa_lead(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_public_qa_lead(UUID, TEXT, TEXT, TEXT) TO anon, authenticated;

-- 8. RPC: list_my_public_qa_sessions (manager 限定)
CREATE OR REPLACE FUNCTION public.list_my_public_qa_sessions(
  p_limit INTEGER DEFAULT 20,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_caller UUID := auth.uid();
  v_items JSON;
  v_total INTEGER;
  v_with_phone INTEGER;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT COUNT(*), COUNT(*) FILTER (WHERE visitor_phone IS NOT NULL)
    INTO v_total, v_with_phone
  FROM manager_public_qa_sessions
  WHERE manager_id = v_caller;

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
      s.created_at
    FROM manager_public_qa_sessions s
    WHERE s.manager_id = v_caller
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
$$;

REVOKE ALL ON FUNCTION public.list_my_public_qa_sessions(INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_public_qa_sessions(INTEGER, INTEGER) TO authenticated;

-- 9. RPC: get_my_public_qa_session_messages (manager 限定，含 session + messages)
CREATE OR REPLACE FUNCTION public.get_my_public_qa_session_messages(p_session_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_caller UUID := auth.uid();
  v_session manager_public_qa_sessions%ROWTYPE;
  v_messages JSON;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT * INTO v_session
  FROM manager_public_qa_sessions
  WHERE id = p_session_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF v_session.manager_id <> v_caller THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT json_agg(t ORDER BY t.created_at) INTO v_messages
  FROM (
    SELECT
      m.id,
      m.role,
      m.content,
      m.citations,
      m.created_at
    FROM manager_public_qa_messages m
    WHERE m.session_id = p_session_id
  ) t;

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
    'messages', COALESCE(v_messages, '[]'::JSON)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_public_qa_session_messages(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_public_qa_session_messages(UUID) TO authenticated;