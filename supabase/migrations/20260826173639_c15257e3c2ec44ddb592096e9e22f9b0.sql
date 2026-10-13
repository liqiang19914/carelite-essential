-- 修正上一版重建时的两处偏差：根判定还原为调用者本人；
-- corp_id/agent_id 恢复「留空=保持原值」，与单聊预留语义一致。
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
  IF auth.uid() IS NULL OR NOT public.is_merchant_root(auth.uid()) THEN
    RAISE EXCEPTION '仅企业负责人可配置企业微信' USING ERRCODE = '42501';
  END IF;
  v_root := auth.uid();

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
        single_chat_corp_id = COALESCE(NULLIF(EXCLUDED.single_chat_corp_id, ''), merchant_wecom_settings.single_chat_corp_id),
        single_chat_agent_id = COALESCE(NULLIF(EXCLUDED.single_chat_agent_id, ''), merchant_wecom_settings.single_chat_agent_id),
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