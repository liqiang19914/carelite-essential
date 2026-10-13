-- 审查修复：回调子域配置列
ALTER TABLE public.merchant_wecom_settings
  ADD COLUMN IF NOT EXISTS callback_domain text;

-- 审查修复 P1#1：读取接口直接验调用者本人，不再把员工映射成负责人
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

-- 审查修复 P1#1：事件列表接口同样直接验调用者本人
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
  IF auth.uid() IS NULL OR NOT public.is_merchant_root(auth.uid()) THEN
    RETURN NULL::jsonb;
  END IF;
  v_root := auth.uid();

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

-- 审查修复 P2#2：回调专用保存接口（只写回调参数与回调子域，不再夹带定时推送配置）
-- 审查修复 P2#1：非空新密钥做裁剪与格式校验（EncodingAESKey 必须 43 位 Base64 字母数字）
CREATE OR REPLACE FUNCTION public.save_merchant_wecom_callback(
  p_single_chat_corp_id text,
  p_single_chat_agent_id text,
  p_single_chat_secret text DEFAULT NULL,
  p_single_chat_token text DEFAULT NULL,
  p_single_chat_aes_key text DEFAULT NULL,
  p_callback_domain text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_corp_id text;
  v_agent_id text;
  v_secret text;
  v_token text;
  v_aes text;
  v_domain text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_merchant_root(auth.uid()) THEN
    RAISE EXCEPTION '仅企业负责人可配置企业微信' USING ERRCODE = '42501';
  END IF;
  v_root := auth.uid();

  v_corp_id := btrim(COALESCE(p_single_chat_corp_id, ''));
  v_agent_id := btrim(COALESCE(p_single_chat_agent_id, ''));
  IF char_length(v_corp_id) > 64 OR char_length(v_agent_id) > 64 THEN
    RAISE EXCEPTION '企业 ID 或应用 AgentId 长度超出限制' USING ERRCODE = 'P0002';
  END IF;

  v_secret := btrim(COALESCE(p_single_chat_secret, ''));
  v_token := btrim(COALESCE(p_single_chat_token, ''));
  v_aes := btrim(COALESCE(p_single_chat_aes_key, ''));
  IF char_length(v_secret) > 512 OR char_length(v_token) > 512 OR char_length(v_aes) > 512 THEN
    RAISE EXCEPTION '密钥参数长度超出限制' USING ERRCODE = 'P0002';
  END IF;
  IF v_aes <> '' AND v_aes !~ '^[A-Za-z0-9+/]{43}$' THEN
    RAISE EXCEPTION 'EncodingAESKey 必须是 43 位字母数字' USING ERRCODE = 'P0002';
  END IF;

  v_domain := lower(btrim(COALESCE(p_callback_domain, '')));
  IF v_domain <> '' THEN
    IF v_domain !~ '^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$' OR v_domain NOT LIKE '%.%' THEN
      RAISE EXCEPTION '回调子域格式不正确，应形如 qywx.example.com' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  INSERT INTO public.merchant_wecom_settings
    (root_manager_id, single_chat_corp_id, single_chat_agent_id,
     single_chat_secret, single_chat_token, single_chat_aes_key,
     callback_domain, single_chat_enabled)
  VALUES
    (v_root, NULLIF(v_corp_id, ''), NULLIF(v_agent_id, ''),
     NULLIF(v_secret, ''), NULLIF(v_token, ''), NULLIF(v_aes, ''),
     NULLIF(v_domain, ''), false)
  ON CONFLICT (root_manager_id) DO UPDATE
    SET single_chat_corp_id = COALESCE(NULLIF(EXCLUDED.single_chat_corp_id, ''), merchant_wecom_settings.single_chat_corp_id),
        single_chat_agent_id = COALESCE(NULLIF(EXCLUDED.single_chat_agent_id, ''), merchant_wecom_settings.single_chat_agent_id),
        single_chat_secret = COALESCE(NULLIF(EXCLUDED.single_chat_secret, ''), merchant_wecom_settings.single_chat_secret),
        single_chat_token = COALESCE(NULLIF(EXCLUDED.single_chat_token, ''), merchant_wecom_settings.single_chat_token),
        single_chat_aes_key = COALESCE(NULLIF(EXCLUDED.single_chat_aes_key, ''), merchant_wecom_settings.single_chat_aes_key),
        callback_domain = COALESCE(NULLIF(EXCLUDED.callback_domain, ''), merchant_wecom_settings.callback_domain),
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

REVOKE ALL ON FUNCTION public.save_merchant_wecom_callback(text, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_merchant_wecom_callback(text, text, text, text, text, text) TO authenticated;