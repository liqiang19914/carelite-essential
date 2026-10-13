-- ── 企微消息回调：验证状态列 ──
ALTER TABLE public.merchant_wecom_settings
  ADD COLUMN IF NOT EXISTS single_chat_callback_verified_at timestamptz,
  ADD COLUMN IF NOT EXISTS single_chat_last_callback_at timestamptz;

-- ── 企微消息回调：事件存储表 ──
CREATE TABLE IF NOT EXISTS public.merchant_wecom_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  dedupe_key text NOT NULL,
  event_type text NOT NULL DEFAULT '',
  msg_type text NOT NULL DEFAULT '',
  wecom_create_time bigint,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  raw_xml text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT merchant_wecom_events_raw_size CHECK (octet_length(raw_xml) <= 65536)
);

CREATE UNIQUE INDEX IF NOT EXISTS merchant_wecom_events_root_dedupe_uidx
  ON public.merchant_wecom_events(root_manager_id, dedupe_key);

CREATE INDEX IF NOT EXISTS merchant_wecom_events_root_created_idx
  ON public.merchant_wecom_events(root_manager_id, created_at DESC);

CREATE INDEX IF NOT EXISTS merchant_wecom_events_root_type_created_idx
  ON public.merchant_wecom_events(root_manager_id, event_type, created_at DESC);

ALTER TABLE public.merchant_wecom_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.merchant_wecom_events FROM anon, authenticated;

-- ── 配置读取：补密钥尾号与回调验证状态（密钥本体永不回传）──
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
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL OR NOT public.is_merchant_root(v_root) THEN
    RETURN NULL::jsonb;
  END IF;

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
      single_chat_callback_verified_at, single_chat_last_callback_at,
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

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.sort_order, t.created_at), '[]'::jsonb) INTO v_tips
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

-- ── 保存配置：Token/AESKey 非空且确实变化时清空回调验证状态 ──
CREATE OR REPLACE FUNCTION public.save_merchant_wecom_settings(
  p_scheduled_enabled boolean,
  p_scheduled_time text,
  p_timezone text,
  p_agent_manager_id uuid,
  p_welcome_message text,
  p_single_chat_corp_id text,
  p_single_chat_agent_id text,
  p_single_chat_secret text DEFAULT NULL,
  p_single_chat_token text DEFAULT NULL,
  p_single_chat_aes_key text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_time text;
  v_tz text;
  v_welcome text;
  v_tips int;
  v_agent uuid;
  v_agent_ok boolean;
  v_corp_id text;
  v_agent_id text;
  v_secret text;
  v_token text;
  v_aes text;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL OR NOT public.is_merchant_root(v_root) THEN
    RAISE EXCEPTION '仅企业负责人可配置企业微信' USING ERRCODE = '42501';
  END IF;

  v_time := btrim(COALESCE(p_scheduled_time, '09:00'));
  IF v_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
    RAISE EXCEPTION '推送时间格式应为 HH:MM（如 09:00）' USING ERRCODE = 'P0002';
  END IF;

  v_tz := btrim(COALESCE(p_timezone, 'Asia/Shanghai'));
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = v_tz) THEN
    RAISE EXCEPTION '时区不存在' USING ERRCODE = 'P0002';
  END IF;

  v_welcome := btrim(COALESCE(p_welcome_message, ''));
  IF char_length(v_welcome) > 500 THEN
    RAISE EXCEPTION '欢迎语不能超过 500 字' USING ERRCODE = 'P0002';
  END IF;

  IF COALESCE(p_scheduled_enabled, false) THEN
    SELECT count(*) INTO v_tips FROM public.merchant_wecom_tips WHERE root_manager_id = v_root;
    IF v_tips < 7 THEN
      RAISE EXCEPTION '开启定时推送前，请先准备至少 7 条健康小贴士' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  v_agent := p_agent_manager_id;
  IF v_agent IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.managers m
      WHERE m.id = v_agent
        AND COALESCE(m.is_system_default, false) = false
        AND public.get_profile_enterprise_id(m.id) = public.get_profile_enterprise_id(v_root)
        AND COALESCE(m.public_qa_enabled, false)
    ) INTO v_agent_ok;
    IF NOT v_agent_ok THEN
      RAISE EXCEPTION '承接智能体必须是本企业已开启公开问答的健管师' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  v_corp_id := btrim(COALESCE(p_single_chat_corp_id, ''));
  v_agent_id := btrim(COALESCE(p_single_chat_agent_id, ''));
  IF char_length(v_corp_id) > 64 OR char_length(v_agent_id) > 64 THEN
    RAISE EXCEPTION '企业 ID 或应用 AgentId 长度超出限制' USING ERRCODE = 'P0002';
  END IF;

  v_secret := COALESCE(p_single_chat_secret, '');
  v_token := COALESCE(p_single_chat_token, '');
  v_aes := COALESCE(p_single_chat_aes_key, '');
  IF char_length(v_secret) > 512 OR char_length(v_token) > 512 OR char_length(v_aes) > 512 THEN
    RAISE EXCEPTION '密钥参数长度超出限制' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.merchant_wecom_settings
    (root_manager_id, scheduled_enabled, scheduled_time, timezone, agent_manager_id,
     welcome_message, single_chat_corp_id, single_chat_agent_id,
     single_chat_secret, single_chat_token, single_chat_aes_key, single_chat_enabled)
  VALUES
    (v_root, COALESCE(p_scheduled_enabled, false), v_time, v_tz, v_agent,
     NULLIF(v_welcome, ''), v_corp_id, v_agent_id,
     NULLIF(v_secret, ''), NULLIF(v_token, ''), NULLIF(v_aes, ''), false)
  ON CONFLICT (root_manager_id) DO UPDATE
    SET scheduled_enabled = EXCLUDED.scheduled_enabled,
        scheduled_time = EXCLUDED.scheduled_time,
        timezone = EXCLUDED.timezone,
        agent_manager_id = EXCLUDED.agent_manager_id,
        welcome_message = EXCLUDED.welcome_message,
        single_chat_corp_id = EXCLUDED.single_chat_corp_id,
        single_chat_agent_id = EXCLUDED.single_chat_agent_id,
        single_chat_secret = COALESCE(NULLIF(EXCLUDED.single_chat_secret, ''), merchant_wecom_settings.single_chat_secret),
        single_chat_token = COALESCE(NULLIF(EXCLUDED.single_chat_token, ''), merchant_wecom_settings.single_chat_token),
        single_chat_aes_key = COALESCE(NULLIF(EXCLUDED.single_chat_aes_key, ''), merchant_wecom_settings.single_chat_aes_key),
        single_chat_callback_verified_at = CASE
          WHEN (NULLIF(EXCLUDED.single_chat_token, '') IS NOT NULL
                AND NULLIF(EXCLUDED.single_chat_token, '') IS DISTINCT FROM merchant_wecom_settings.single_chat_token)
            OR (NULLIF(EXCLUDED.single_chat_aes_key, '') IS NOT NULL
                AND NULLIF(EXCLUDED.single_chat_aes_key, '') IS DISTINCT FROM merchant_wecom_settings.single_chat_aes_key)
          THEN NULL
          ELSE merchant_wecom_settings.single_chat_callback_verified_at
        END,
        single_chat_enabled = false,
        updated_at = now();

  RETURN public.get_merchant_wecom_config();
END;
$function$;

REVOKE ALL ON FUNCTION public.save_merchant_wecom_settings(boolean, text, text, uuid, text, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_merchant_wecom_settings(boolean, text, text, uuid, text, text, text, text, text, text) TO authenticated;

-- ── 事件记录分页查看（商户根；不回传 raw_xml）──
CREATE OR REPLACE FUNCTION public.list_merchant_wecom_events(
  p_limit int DEFAULT 20,
  p_offset int DEFAULT 0,
  p_event_type text DEFAULT NULL
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
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL OR NOT public.is_merchant_root(v_root) THEN
    RETURN NULL::jsonb;
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);

  SELECT count(*) INTO v_total
  FROM public.merchant_wecom_events
  WHERE root_manager_id = v_root
    AND (p_event_type IS NULL OR btrim(p_event_type) = '' OR event_type = btrim(p_event_type));

  SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.created_at DESC), '[]'::jsonb) INTO v_items
  FROM (
    SELECT id, event_type, msg_type, wecom_create_time, payload, created_at
    FROM public.merchant_wecom_events
    WHERE root_manager_id = v_root
      AND (p_event_type IS NULL OR btrim(p_event_type) = '' OR event_type = btrim(p_event_type))
    ORDER BY created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) e;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_merchant_wecom_events(int, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_merchant_wecom_events(int, int, text) TO authenticated;