-- ============================================================================
-- 门店体系 RPC 组 C：商户咨询配置 + 公开问答人工回复链路
-- ============================================================================

-- ── 商户：保存咨询配置（channels 白名单校验；AI 健管师必须同企业）──
CREATE OR REPLACE FUNCTION public.save_merchant_consult_settings(
  p_channels TEXT[],
  p_ai_manager_id UUID,
  p_human_handoff_enabled BOOLEAN,
  p_wecom_qr_url TEXT,
  p_wecom_acquisition_url TEXT,
  p_miniapp_contact_enabled BOOLEAN
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
    ai_manager_id = CASE WHEN p_ai_manager_id IS NULL THEN merchant_consult_settings.ai_manager_id ELSE EXCLUDED.ai_manager_id END,
    human_handoff_enabled = COALESCE(EXCLUDED.human_handoff_enabled, false),
    wecom_qr_url = CASE WHEN p_wecom_qr_url IS NULL THEN merchant_consult_settings.wecom_qr_url ELSE EXCLUDED.wecom_qr_url END,
    wecom_acquisition_url = CASE WHEN p_wecom_acquisition_url IS NULL THEN merchant_consult_settings.wecom_acquisition_url ELSE EXCLUDED.wecom_acquisition_url END,
    miniapp_contact_enabled = COALESCE(EXCLUDED.miniapp_contact_enabled, false),
    updated_at = now();

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.save_merchant_consult_settings(TEXT[], UUID, BOOLEAN, TEXT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_merchant_consult_settings(TEXT[], UUID, BOOLEAN, TEXT, TEXT, BOOLEAN) TO authenticated;

-- ── 商户：读本企业咨询配置 ─────────────────────────────────────────
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
    'updated_at', v_row.updated_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_merchant_consult_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_merchant_consult_settings() TO authenticated;

-- ── 公开：客户端拉商户咨询配置（anon；按企业根）───────────────────
CREATE OR REPLACE FUNCTION public.get_public_merchant_consult_settings(p_root_manager_id UUID)
RETURNS JSON
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
    FROM public.managers m WHERE m.id = v_row.ai_manager_id;
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

REVOKE ALL ON FUNCTION public.get_public_merchant_consult_settings(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_merchant_consult_settings(UUID) TO anon, authenticated;

-- ── 人工回复：商户向访客会话发送消息（role=manager）───────────────
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
  v_msg_id UUID;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF btrim(COALESCE(p_content, '')) = '' OR char_length(btrim(p_content)) > 2000 THEN
    RAISE EXCEPTION '回复内容不能为空且不超过 2000 字' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_session FROM public.manager_public_qa_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '会话不存在' USING ERRCODE = '22023';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  -- 本人健管师或同企业商户都可回复（企业根校验覆盖员工）
  IF v_session.manager_id IS DISTINCT FROM v_uid
     AND v_root IS DISTINCT FROM public.get_enterprise_root_manager_id(v_session.manager_id) THEN
    RAISE EXCEPTION '你没有回复这个会话的权限' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.manager_public_qa_messages (session_id, role, content)
  VALUES (v_session.id, 'manager', btrim(p_content))
  RETURNING id INTO v_msg_id;

  UPDATE public.manager_public_qa_sessions
     SET message_count = message_count + 1,
         last_active_at = now()
   WHERE id = v_session.id;

  RETURN json_build_object('success', true, 'message_id', v_msg_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.send_public_qa_manager_message(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_public_qa_manager_message(UUID, TEXT) TO authenticated;

-- ── 访客增量拉取：凭 visitor_token 读回会话消息（含人工回复）──────
CREATE OR REPLACE FUNCTION public.get_public_qa_visitor_messages(
  p_manager_id UUID,
  p_visitor_token TEXT,
  p_session_id UUID,
  p_after_id UUID DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_session public.manager_public_qa_sessions%ROWTYPE;
  v_items JSON;
BEGIN
  IF p_manager_id IS NULL OR p_visitor_token IS NULL OR p_session_id IS NULL THEN
    RETURN json_build_object('items', '[]'::JSON);
  END IF;
  SELECT * INTO v_session
  FROM public.manager_public_qa_sessions
  WHERE id = p_session_id AND manager_id = p_manager_id AND visitor_token = p_visitor_token;
  IF NOT FOUND THEN
    RETURN json_build_object('items', '[]'::JSON);
  END IF;

  SELECT json_agg(t ORDER BY t.created_at) INTO v_items
  FROM (
    SELECT m.id, m.role, m.content, m.citations, m.created_at
    FROM public.manager_public_qa_messages m
    WHERE m.session_id = v_session.id
      AND (p_after_id IS NULL OR m.id > p_after_id)
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_qa_visitor_messages(UUID, TEXT, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_qa_visitor_messages(UUID, TEXT, UUID, UUID) TO anon, authenticated;

-- ── 公开：可申请入驻的商户列表（门店模块双闸门开启 + 已认证）──────
CREATE OR REPLACE FUNCTION public.list_store_merchants_open()
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_items JSON;
BEGIN
  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT m.id, m.business_name, m.partner_card_display_name,
           m.partner_card_avatar_url, m.company_name
    FROM public.managers m
    WHERE m.certification_status = 'approved'
      AND public._store_module_on(m.id)
    ORDER BY m.created_at DESC
    LIMIT 100
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;

REVOKE ALL ON FUNCTION public.list_store_merchants_open() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_store_merchants_open() TO anon, authenticated;