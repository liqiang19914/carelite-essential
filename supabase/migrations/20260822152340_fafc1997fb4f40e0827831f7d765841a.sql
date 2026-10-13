-- 修复 1：保存咨询配置需商城设置权限（企业主或持有 shop_settings 权限的角色）
CREATE OR REPLACE FUNCTION public.save_merchant_consult_settings(p_channels text[], p_ai_manager_id uuid, p_human_handoff_enabled boolean, p_wecom_qr_url text, p_wecom_acquisition_url text, p_miniapp_contact_enabled boolean)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_channel TEXT;
  v_ok BOOLEAN;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '只有商户账号可以配置咨询方式' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('shop_settings', v_uid) THEN
    RAISE EXCEPTION '你没有商城设置权限' USING ERRCODE = '42501';
  END IF;

  v_ok := true;
  IF p_channels IS NOT NULL THEN
    FOREACH v_channel IN ARRAY p_channels LOOP
      IF v_channel NOT IN ('ai','miniapp_contact','wecom_qr','wecom_acquisition') THEN
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

  INSERT INTO public.merchant_consult_settings (
    root_manager_id, channels, ai_manager_id, human_handoff_enabled,
    wecom_qr_url, wecom_acquisition_url, miniapp_contact_enabled
  ) VALUES (
    v_root, COALESCE(p_channels, '{}'), p_ai_manager_id,
    COALESCE(p_human_handoff_enabled, false),
    btrim(COALESCE(p_wecom_qr_url, '')), btrim(COALESCE(p_wecom_acquisition_url, '')),
    COALESCE(p_miniapp_contact_enabled, false)
  )
  ON CONFLICT (root_manager_id) DO UPDATE SET
    channels = COALESCE(EXCLUDED.channels, merchant_consult_settings.channels),
    ai_manager_id = EXCLUDED.ai_manager_id,
    human_handoff_enabled = COALESCE(EXCLUDED.human_handoff_enabled, false),
    wecom_qr_url = EXCLUDED.wecom_qr_url,
    wecom_acquisition_url = EXCLUDED.wecom_acquisition_url,
    miniapp_contact_enabled = COALESCE(EXCLUDED.miniapp_contact_enabled, false),
    updated_at = now();

  RETURN json_build_object('success', true);
END;
$function$;

-- 修复 2：ai_ready 复用公开问答真实就绪条件（公开问答开启 + 知识库就绪）
CREATE OR REPLACE FUNCTION public.get_public_merchant_consult_settings(p_root_manager_id uuid)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_row public.merchant_consult_settings%ROWTYPE;
  v_ai_short TEXT;
  v_ai_name TEXT;
  v_ai_ready BOOLEAN;
BEGIN
  IF p_root_manager_id IS NULL THEN
    RETURN json_build_object('configured', false);
  END IF;
  SELECT * INTO v_row FROM public.merchant_consult_settings WHERE root_manager_id = p_root_manager_id;
  IF NOT FOUND THEN
    RETURN json_build_object('configured', false);
  END IF;

  v_ai_ready := false;
  IF v_row.ai_manager_id IS NOT NULL AND v_row.channels @> ARRAY['ai'] THEN
    SELECT m.short_code, m.partner_card_display_name
      INTO v_ai_short, v_ai_name
    FROM public.managers m
    WHERE m.id = v_row.ai_manager_id
      AND m.public_qa_enabled = true
      AND m.knowledge_index_status = 'ready';
    IF v_ai_short IS NOT NULL THEN
      v_ai_ready := true;
    END IF;
  END IF;

  RETURN json_build_object(
    'configured', true,
    'channels', v_row.channels,
    'ai_manager_id', v_row.ai_manager_id,
    'ai_manager_short_code', COALESCE(v_ai_short, ''),
    'ai_manager_name', COALESCE(v_ai_name, ''),
    'ai_ready', v_ai_ready,
    'human_handoff_enabled', v_row.human_handoff_enabled,
    'wecom_qr_url', v_row.wecom_qr_url,
    'wecom_acquisition_url', v_row.wecom_acquisition_url,
    'miniapp_contact_enabled', v_row.miniapp_contact_enabled
  );
END;
$function$;

-- 修复 3：人工回复权限收紧 + 不再虚增轮数
CREATE OR REPLACE FUNCTION public.send_public_qa_manager_message(
  p_session_id UUID,
  p_content TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_session public.manager_public_qa_sessions%ROWTYPE;
  v_cfg public.merchant_consult_settings%ROWTYPE;
  v_msg_id UUID;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF btrim(COALESCE(p_content, '')) = '' OR char_length(btrim(p_content)) > 2000 THEN
    RAISE EXCEPTION '回复内容不能为空且不超过 2000 字' USING ERRCODE = '22023';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '只有商户账号可以回复' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('shop_settings', v_uid) THEN
    RAISE EXCEPTION '你没有商城设置权限' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_session FROM public.manager_public_qa_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '会话不存在' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_cfg FROM public.merchant_consult_settings WHERE root_manager_id = v_root;
  IF NOT FOUND
     OR v_cfg.ai_manager_id IS NULL
     OR NOT (v_cfg.channels @> ARRAY['ai'])
     OR NOT v_cfg.human_handoff_enabled THEN
    RAISE EXCEPTION '未开启人工接着回复' USING ERRCODE = '42501';
  END IF;

  IF v_session.manager_id IS DISTINCT FROM v_cfg.ai_manager_id THEN
    RAISE EXCEPTION '该会话不是当前商城客服的会话' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.manager_public_qa_messages (session_id, role, content)
  VALUES (v_session.id, 'manager', btrim(p_content))
  RETURNING id INTO v_msg_id;

  UPDATE public.manager_public_qa_sessions
     SET last_active_at = now()
   WHERE id = v_session.id;

  RETURN json_build_object('success', true, 'message_id', v_msg_id);
END;
$function$;

-- 修复 4：商户视角读取商城客服（咨询配置所选智能体）的访客会话
CREATE OR REPLACE FUNCTION public.list_consult_public_qa_sessions(
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
  v_root UUID;
  v_cfg public.merchant_consult_settings%ROWTYPE;
  v_items JSON;
  v_total INTEGER;
  v_with_phone INTEGER;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_caller);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '只有商户账号可以查看' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('shop_settings', v_caller) THEN
    RAISE EXCEPTION '你没有商城设置权限' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_cfg FROM public.merchant_consult_settings WHERE root_manager_id = v_root;
  IF NOT FOUND OR v_cfg.ai_manager_id IS NULL THEN
    RETURN json_build_object('items', '[]'::JSON, 'total', 0, 'with_phone_count', 0);
  END IF;

  SELECT COUNT(*), COUNT(*) FILTER (WHERE visitor_phone IS NOT NULL)
    INTO v_total, v_with_phone
  FROM manager_public_qa_sessions
  WHERE manager_id = v_cfg.ai_manager_id;

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
    WHERE s.manager_id = v_cfg.ai_manager_id
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

REVOKE ALL ON FUNCTION public.list_consult_public_qa_sessions(INTEGER, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_consult_public_qa_sessions(INTEGER, INTEGER) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_consult_public_qa_session_messages(p_session_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller UUID := auth.uid();
  v_root UUID;
  v_cfg public.merchant_consult_settings%ROWTYPE;
  v_session manager_public_qa_sessions%ROWTYPE;
  v_messages JSON;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_caller);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '只有商户账号可以查看' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('shop_settings', v_caller) THEN
    RAISE EXCEPTION '你没有商城设置权限' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_cfg FROM public.merchant_consult_settings WHERE root_manager_id = v_root;
  IF NOT FOUND OR v_cfg.ai_manager_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_session
  FROM manager_public_qa_sessions
  WHERE id = p_session_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF v_session.manager_id <> v_cfg.ai_manager_id THEN
    RAISE EXCEPTION '无权查看该会话' USING ERRCODE = '42501';
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
$function$;

REVOKE ALL ON FUNCTION public.get_consult_public_qa_session_messages(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_consult_public_qa_session_messages(UUID) TO authenticated;