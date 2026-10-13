-- 微信客服：验证状态列
ALTER TABLE public.merchant_wecom_settings
  ADD COLUMN IF NOT EXISTS kf_verified_at timestamptz,
  ADD COLUMN IF NOT EXISTS kf_last_callback_at timestamptz;

-- 微信客服会话（客户是微信侧外部身份，不挂 auth.users）
CREATE TABLE IF NOT EXISTS public.merchant_wecom_kf_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  open_kfid text NOT NULL,
  external_user_id text NOT NULL,
  kf_mode text NOT NULL DEFAULT 'hybrid'
    CHECK (kf_mode IN ('human','ai','hybrid')),
  ai_agent_manager_id uuid REFERENCES public.managers(id) ON DELETE SET NULL,
  is_taken_over boolean NOT NULL DEFAULT false,
  last_message_text text,
  last_event_type text,
  last_event_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_kf_conversation UNIQUE (root_manager_id, open_kfid, external_user_id)
);

CREATE INDEX IF NOT EXISTS idx_kf_conversations_root
  ON public.merchant_wecom_kf_conversations (root_manager_id, last_event_at DESC);

-- 微信客服消息（wecom_msg_id 幂等；内容只放正文，原文存 raw_event）
CREATE TABLE IF NOT EXISTS public.merchant_wecom_kf_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL
    REFERENCES public.merchant_wecom_kf_conversations(id) ON DELETE CASCADE,
  sender_type text NOT NULL CHECK (sender_type IN ('customer','manager','ai','system')),
  msg_type text,
  content text,
  raw_event jsonb,
  wecom_msg_id text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_kf_message UNIQUE (conversation_id, wecom_msg_id)
);

CREATE INDEX IF NOT EXISTS idx_kf_messages_conversation
  ON public.merchant_wecom_kf_messages (conversation_id, created_at);

ALTER TABLE public.merchant_wecom_kf_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.merchant_wecom_kf_messages ENABLE ROW LEVEL SECURITY;

-- 配置读取接口扩展微信客服摘要（不返回密钥明文）
CREATE OR REPLACE FUNCTION public.get_merchant_wecom_config()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_settings jsonb;
  v_groups jsonb;
  v_tips jsonb;
  v_tip_count int;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_merchant_root(auth.uid()) THEN
    RETURN NULL::jsonb;
  END IF;
  v_root := auth.uid();

  SELECT to_jsonb(s) INTO v_settings
  FROM (
    SELECT
      id, root_manager_id, scheduled_enabled, scheduled_time, timezone,
      agent_manager_id, welcome_message,
      single_chat_corp_id, single_chat_agent_id, single_chat_enabled,
      (single_chat_secret IS NOT NULL AND single_chat_secret <> '') AS has_single_chat_secret,
      right(single_chat_secret, 4) AS single_chat_secret_tail,
      (single_chat_token IS NOT NULL AND single_chat_token <> '') AS has_single_chat_token,
      right(single_chat_token, 4) AS single_chat_token_tail,
      (single_chat_aes_key IS NOT NULL AND single_chat_aes_key <> '') AS has_single_chat_aes_key,
      right(single_chat_aes_key, 4) AS single_chat_aes_tail,
      callback_domain,
      single_chat_callback_verified_at, single_chat_last_callback_at,
      kf_open_kfid,
      (kf_token IS NOT NULL AND kf_token <> '') AS has_kf_token,
      right(kf_token, 4) AS kf_token_tail,
      (kf_aes_key IS NOT NULL AND kf_aes_key <> '') AS has_kf_aes_key,
      right(kf_aes_key, 4) AS kf_aes_tail,
      kf_mode, kf_ai_agent_manager_id, kf_verified_at, kf_last_callback_at,
      tip_cursor, last_scheduled_date, created_at, updated_at
    FROM public.merchant_wecom_settings
    WHERE root_manager_id = v_root
  ) s;

  SELECT COALESCE(jsonb_agg(to_jsonb(g) ORDER BY g.created_at), '[]'::jsonb) INTO v_groups
  FROM (
    SELECT
      id, name,
      CASE WHEN webhook_url LIKE '%key=%' THEN right(webhook_url, 6) ELSE '' END AS webhook_key_tail,
      enabled, consecutive_failures, disabled_reason, last_push_at, created_at
    FROM public.merchant_wecom_groups
    WHERE root_manager_id = v_root
  ) g;

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.sort_order, t.id), '[]'::jsonb) INTO v_tips
  FROM (
    SELECT id, content, sort_order
    FROM public.merchant_wecom_tips
    WHERE root_manager_id = v_root
  ) t;

  SELECT count(*) INTO v_tip_count
  FROM public.merchant_wecom_tips
  WHERE root_manager_id = v_root;

  RETURN jsonb_build_object(
    'settings', COALESCE(v_settings, '{}'::jsonb),
    'groups', v_groups,
    'tips', v_tips,
    'tip_count', v_tip_count
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_merchant_wecom_config() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_merchant_wecom_config() TO authenticated;

-- 微信客服配置保存：留空保持原值；OpenKfId/Token/AESKey 变化清验证时间；
-- 接待模式三选一；承接智能体必须是本企业员工
CREATE OR REPLACE FUNCTION public.save_merchant_wecom_kf(
  p_kf_open_kfid text DEFAULT NULL,
  p_kf_token text DEFAULT NULL,
  p_kf_aes_key text DEFAULT NULL,
  p_kf_mode text DEFAULT NULL,
  p_kf_ai_agent_manager_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_open_kfid text;
  v_token text;
  v_aes text;
  v_mode text;
  v_agent uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_merchant_root(auth.uid()) THEN
    RAISE EXCEPTION '仅企业负责人可配置企业微信' USING ERRCODE = '42501';
  END IF;
  v_root := auth.uid();

  v_open_kfid := btrim(COALESCE(p_kf_open_kfid, ''));
  v_token := btrim(COALESCE(p_kf_token, ''));
  v_aes := btrim(COALESCE(p_kf_aes_key, ''));
  IF char_length(v_open_kfid) > 64 OR char_length(v_token) > 512 OR char_length(v_aes) > 512 THEN
    RAISE EXCEPTION '微信客服参数长度超出限制' USING ERRCODE = 'P0002';
  END IF;
  IF v_aes <> '' AND v_aes !~ '^[A-Za-z0-9+/]{43}$' THEN
    RAISE EXCEPTION 'EncodingAESKey 必须是 43 位字母数字' USING ERRCODE = 'P0002';
  END IF;

  v_mode := btrim(COALESCE(p_kf_mode, ''));
  IF v_mode <> '' AND v_mode NOT IN ('human','ai','hybrid') THEN
    RAISE EXCEPTION '接待模式仅支持人工 / AI / 混合三种' USING ERRCODE = 'P0002';
  END IF;

  v_agent := NULL;
  IF p_kf_ai_agent_manager_id IS NOT NULL AND btrim(p_kf_ai_agent_manager_id) <> '' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.managers WHERE id = p_kf_ai_agent_manager_id::uuid
    ) THEN
      RAISE EXCEPTION '承接智能体不存在' USING ERRCODE = 'P0002';
    END IF;
    IF public.get_enterprise_root_manager_id(p_kf_ai_agent_manager_id::uuid) IS DISTINCT FROM v_root THEN
      RAISE EXCEPTION '承接智能体必须是本企业员工' USING ERRCODE = '42501';
    END IF;
    v_agent := p_kf_ai_agent_manager_id::uuid;
  END IF;

  INSERT INTO public.merchant_wecom_settings
    (root_manager_id, kf_open_kfid, kf_token, kf_aes_key, kf_mode, kf_ai_agent_manager_id)
  VALUES
    (v_root, NULLIF(v_open_kfid, ''), NULLIF(v_token, ''), NULLIF(v_aes, ''),
     COALESCE(NULLIF(v_mode, ''), 'hybrid'), v_agent)
  ON CONFLICT (root_manager_id) DO UPDATE
    SET kf_open_kfid = COALESCE(NULLIF(EXCLUDED.kf_open_kfid, ''), merchant_wecom_settings.kf_open_kfid),
        kf_token = COALESCE(NULLIF(EXCLUDED.kf_token, ''), merchant_wecom_settings.kf_token),
        kf_aes_key = COALESCE(NULLIF(EXCLUDED.kf_aes_key, ''), merchant_wecom_settings.kf_aes_key),
        kf_mode = CASE
          WHEN NULLIF(v_mode, '') IS NULL THEN merchant_wecom_settings.kf_mode
          ELSE EXCLUDED.kf_mode
        END,
        kf_ai_agent_manager_id = v_agent,
        kf_verified_at = CASE
          WHEN (NULLIF(EXCLUDED.kf_open_kfid, '') IS NOT NULL
                AND NULLIF(EXCLUDED.kf_open_kfid, '') IS DISTINCT FROM merchant_wecom_settings.kf_open_kfid)
            OR (NULLIF(EXCLUDED.kf_token, '') IS NOT NULL
                AND NULLIF(EXCLUDED.kf_token, '') IS DISTINCT FROM merchant_wecom_settings.kf_token)
            OR (NULLIF(EXCLUDED.kf_aes_key, '') IS NOT NULL
                AND NULLIF(EXCLUDED.kf_aes_key, '') IS DISTINCT FROM merchant_wecom_settings.kf_aes_key)
          THEN NULL
          ELSE merchant_wecom_settings.kf_verified_at
        END,
        updated_at = now();

  RETURN public.get_merchant_wecom_config();
END;
$function$;

REVOKE ALL ON FUNCTION public.save_merchant_wecom_kf(text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_merchant_wecom_kf(text, text, text, text, text) TO authenticated;

-- 微信客服会话列表：管理员全量，企业员工看本企业根
CREATE OR REPLACE FUNCTION public.list_merchant_wecom_kf_conversations(
  p_limit int DEFAULT 20,
  p_offset int DEFAULT 0,
  p_root_manager_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_limit int;
  v_offset int;
  v_total int;
  v_items jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NULL::jsonb;
  END IF;

  IF public.is_admin(auth.uid()) THEN
    v_root := p_root_manager_id;
  ELSE
    v_root := public.get_enterprise_root_manager_id(auth.uid());
    IF v_root IS NULL THEN
      RETURN jsonb_build_object('items', '[]'::jsonb, 'total', 0);
    END IF;
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);

  SELECT count(*) INTO v_total
  FROM public.merchant_wecom_kf_conversations
  WHERE (v_root IS NULL OR root_manager_id = v_root);

  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.last_event_at DESC NULLS LAST), '[]'::jsonb) INTO v_items
  FROM (
    SELECT
      kc.id, kc.root_manager_id, kc.open_kfid, kc.external_user_id,
      kc.kf_mode, kc.ai_agent_manager_id, kc.is_taken_over,
      kc.last_message_text, kc.last_event_type, kc.last_event_at,
      kc.created_at,
      COALESCE(NULLIF(m.business_name, ''), NULLIF(m.company_name, ''), m.id::text) AS merchant_name
    FROM public.merchant_wecom_kf_conversations kc
    LEFT JOIN public.managers m ON m.id = kc.root_manager_id
    WHERE (v_root IS NULL OR kc.root_manager_id = v_root)
    ORDER BY kc.last_event_at DESC NULLS LAST
    LIMIT v_limit OFFSET v_offset
  ) c;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_merchant_wecom_kf_conversations(int, int, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_merchant_wecom_kf_conversations(int, int, uuid) TO authenticated;

-- 微信客服会话消息：管理员全量，企业员工校验会话属于本企业根
CREATE OR REPLACE FUNCTION public.get_merchant_wecom_kf_messages(
  p_conversation_id uuid,
  p_limit int DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_conv_root uuid;
  v_limit int;
  v_items jsonb;
BEGIN
  IF auth.uid() IS NULL OR p_conversation_id IS NULL THEN
    RETURN NULL::jsonb;
  END IF;

  SELECT root_manager_id INTO v_conv_root
  FROM public.merchant_wecom_kf_conversations
  WHERE id = p_conversation_id;
  IF v_conv_root IS NULL THEN
    RETURN jsonb_build_object('items', '[]'::jsonb, 'total', 0);
  END IF;

  IF NOT public.is_admin(auth.uid()) THEN
    v_root := public.get_enterprise_root_manager_id(auth.uid());
    IF v_root IS DISTINCT FROM v_conv_root THEN
      RETURN NULL::jsonb;
    END IF;
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);

  SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.created_at ASC), '[]'::jsonb) INTO v_items
  FROM (
    SELECT id, sender_type, msg_type, content, wecom_msg_id, created_at
    FROM public.merchant_wecom_kf_messages
    WHERE conversation_id = p_conversation_id
    ORDER BY created_at ASC
    LIMIT v_limit
  ) m;

  RETURN jsonb_build_object('items', v_items, 'total', jsonb_array_length(v_items));
END;
$function$;

REVOKE ALL ON FUNCTION public.get_merchant_wecom_kf_messages(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_merchant_wecom_kf_messages(uuid, int) TO authenticated;