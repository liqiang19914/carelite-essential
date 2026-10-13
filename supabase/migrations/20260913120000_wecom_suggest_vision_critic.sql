-- 推荐话术增强：
-- 1) 多模态：客户发的图片/PDF/Word/Excel 由视觉模型识别（描述持久化在消息 content.visionDesc，无需新列）
-- 2) 评审 Agent：商户级开关 + 额外评审要求，存 merchant_wecom_settings；
--    日志记 critic_used 便于追踪评审是否参与本次生成

ALTER TABLE public.merchant_wecom_settings
  ADD COLUMN IF NOT EXISTS suggest_critic_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS suggest_critic_prompt text;

COMMENT ON COLUMN public.merchant_wecom_settings.suggest_critic_enabled IS '推荐话术评审 Agent 开关（默认开）：生成后二次把关改写';
COMMENT ON COLUMN public.merchant_wecom_settings.suggest_critic_prompt IS '评审 Agent 额外评审要求（商户自定义，可空）';

ALTER TABLE public.wecom_reply_suggestion_logs
  ADD COLUMN IF NOT EXISTS critic_used boolean;

-- ── 存档配置读取：追加评审 Agent 两个配置 ──
DROP FUNCTION IF EXISTS public.get_wecom_pro_archive_config();
CREATE FUNCTION public.get_wecom_pro_archive_config()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_s public.merchant_wecom_settings%ROWTYPE;
  v_slug text;
  v_room_count int;
  v_msg_count bigint;
  v_today_msg int;
  v_sensitive_count int;
  v_latest_msg bigint;
  v_platform_ip text;
  v_event_url text;
  v_event_ready boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;
  IF NOT public.wecom_archive_readable(v_root) THEN
    RAISE EXCEPTION '企微助手 Pro 尚未开通' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('wecom_pro_archive', v_uid) THEN
    RAISE EXCEPTION '没有会话存档权限' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_s FROM public.merchant_wecom_settings WHERE root_manager_id = v_root;
  SELECT btrim(brand_slug) INTO v_slug FROM public.managers WHERE id = v_root;

  IF COALESCE(btrim(v_s.callback_domain), '') <> '' AND COALESCE(v_slug, '') <> '' THEN
    v_event_url := 'https://' || btrim(v_s.callback_domain) || '/wecom/callback?slug=' || v_slug;
  END IF;
  v_event_ready := v_event_url IS NOT NULL
                   AND COALESCE(btrim(v_s.single_chat_token), '') <> ''
                   AND COALESCE(btrim(v_s.single_chat_aes_key), '') <> '';

  SELECT NULLIF(btrim(value), '') INTO v_platform_ip
  FROM public.system_settings
  WHERE key = 'wecom_archive_collector_ip';

  SELECT
    (SELECT count(*)::int FROM public.merchant_wecom_archive_rooms WHERE root_manager_id = v_root),
    (SELECT count(*) FROM public.merchant_wecom_archive_messages WHERE root_manager_id = v_root),
    (SELECT count(*)::int FROM public.merchant_wecom_archive_messages
      WHERE root_manager_id = v_root AND created_at >= date_trunc('day', now())),
    (SELECT count(*)::int FROM public.merchant_wecom_archive_messages
      WHERE root_manager_id = v_root AND sensitive_hit),
    (SELECT (max(msgtime) / 1000)::bigint FROM public.merchant_wecom_archive_messages
      WHERE root_manager_id = v_root)
  INTO v_room_count, v_msg_count, v_today_msg, v_sensitive_count, v_latest_msg;

  RETURN jsonb_build_object(
    'enabled', COALESCE(v_s.archive_enabled, false),
    'moduleOpen', public.wecom_pro_module_open(v_root),
    'hasSecret', COALESCE(v_s.archive_secret, '') <> '',
    'secretTail', CASE WHEN COALESCE(v_s.archive_secret, '') <> ''
                       THEN right(v_s.archive_secret, 4) ELSE NULL END,
    'privateKeys', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('publickeyVer', k->>'publickey_ver', 'hasKey', true)
                       ORDER BY k->>'publickey_ver')
      FROM jsonb_array_elements(COALESCE(v_s.archive_private_keys, '[]'::jsonb)) k
    ), '[]'::jsonb),
    'checkedAt', v_s.archive_checked_at,
    'lastSeq', COALESCE(v_s.archive_last_seq, 0),
    'collectorHeartbeat', v_s.archive_collector_heartbeat,
    'collectorIp', v_s.archive_collector_ip,
    'collectorError', NULLIF(btrim(COALESCE(v_s.archive_collector_error, '')), ''),
    'platformCollectorIp', v_platform_ip,
    'corpId', NULLIF(btrim(COALESCE(v_s.single_chat_corp_id, '')), ''),
    'eventServerUrl', v_event_url,
    'eventServerToken', NULLIF(btrim(COALESCE(v_s.single_chat_token, '')), ''),
    'eventServerAesKey', NULLIF(btrim(COALESCE(v_s.single_chat_aes_key, '')), ''),
    'eventServerReady', v_event_ready,
    'suggestCriticEnabled', COALESCE(v_s.suggest_critic_enabled, true),
    'suggestCriticPrompt', NULLIF(btrim(COALESCE(v_s.suggest_critic_prompt, '')), ''),
    'roomCount', COALESCE(v_room_count, 0),
    'messageCount', COALESCE(v_msg_count, 0),
    'todayMessageCount', COALESCE(v_today_msg, 0),
    'sensitiveCount', COALESCE(v_sensitive_count, 0),
    'latestMessageAt', v_latest_msg
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_wecom_pro_archive_config() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wecom_pro_archive_config() TO authenticated;

-- ── 存档配置保存：追加评审 Agent 参数（NULL=不变） ──
DROP FUNCTION IF EXISTS public.save_wecom_pro_archive_config(text, jsonb, int, boolean);
CREATE FUNCTION public.save_wecom_pro_archive_config(
  p_secret text DEFAULT NULL,
  p_merge_private_key jsonb DEFAULT NULL,
  p_remove_publickey_ver int DEFAULT NULL,
  p_enabled boolean DEFAULT NULL,
  p_critic_enabled boolean DEFAULT NULL,
  p_critic_prompt text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_secret text;
  v_keys jsonb;
  v_enabled boolean;
  v_merge_ver int;
  v_existing_secret text;
  v_prompt text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;
  IF NOT public.wecom_pro_module_open(v_root) THEN
    RAISE EXCEPTION '企微助手 Pro 尚未开通' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('wecom_pro_archive', v_uid) THEN
    RAISE EXCEPTION '没有会话存档配置权限' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.merchant_wecom_settings (root_manager_id)
  VALUES (v_root)
  ON CONFLICT (root_manager_id) DO NOTHING;

  -- secret：NULL 不变；空串清空；最长 200
  IF p_secret IS NOT NULL THEN
    v_secret := btrim(p_secret);
    IF v_secret <> '' AND char_length(v_secret) > 200 THEN
      RAISE EXCEPTION '存档 Secret 长度不合法' USING ERRCODE = '23514';
    END IF;
  END IF;

  SELECT COALESCE(archive_secret, ''), COALESCE(archive_private_keys, '[]'::jsonb)
  INTO v_existing_secret, v_keys
  FROM public.merchant_wecom_settings
  WHERE root_manager_id = v_root;

  -- 合并单个私钥版本（同版本覆盖）
  IF p_merge_private_key IS NOT NULL THEN
    IF jsonb_typeof(p_merge_private_key) <> 'object'
       OR COALESCE(btrim(p_merge_private_key->>'private_key_pem'), '') = ''
       OR p_merge_private_key->>'publickey_ver' IS NULL THEN
      RAISE EXCEPTION '私钥配置缺少公钥版本或私钥内容' USING ERRCODE = '22023';
    END IF;
    v_merge_ver := (p_merge_private_key->>'publickey_ver')::int;
    IF v_merge_ver IS NULL OR v_merge_ver < 1 OR v_merge_ver > 10000 THEN
      RAISE EXCEPTION '公钥版本号不合法（1-10000）' USING ERRCODE = '22023';
    END IF;
    IF p_merge_private_key->>'private_key_pem' NOT LIKE '%PRIVATE KEY%' THEN
      RAISE EXCEPTION '私钥内容不是合法的 PEM 格式' USING ERRCODE = '22023';
    END IF;

    SELECT COALESCE(jsonb_agg(elem ORDER BY (elem->>'publickey_ver')::int), '[]'::jsonb)
    INTO v_keys
    FROM jsonb_array_elements(v_keys) elem
    WHERE (elem->>'publickey_ver')::int <> v_merge_ver;

    v_keys := v_keys || jsonb_build_array(p_merge_private_key);
  END IF;

  -- 删除单个私钥版本（启用中不允许删到一把不剩）
  IF p_remove_publickey_ver IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(elem ORDER BY (elem->>'publickey_ver')::int), '[]'::jsonb)
    INTO v_keys
    FROM jsonb_array_elements(v_keys) elem
    WHERE (elem->>'publickey_ver')::int <> p_remove_publickey_ver;
  END IF;

  v_enabled := COALESCE(p_enabled,
    (SELECT archive_enabled FROM public.merchant_wecom_settings WHERE root_manager_id = v_root));

  IF v_enabled AND COALESCE(NULLIF(v_secret, ''), v_existing_secret) = '' THEN
    RAISE EXCEPTION '启用采集前请先填写会话存档 Secret' USING ERRCODE = '22023';
  END IF;
  IF v_enabled AND jsonb_array_length(COALESCE(v_keys, '[]'::jsonb)) = 0 THEN
    RAISE EXCEPTION '启用采集前请先生成并保存加密密钥对' USING ERRCODE = '22023';
  END IF;

  -- 评审要求：NULL 不变；空串清空；最长 2000
  IF p_critic_prompt IS NOT NULL THEN
    v_prompt := btrim(p_critic_prompt);
    IF char_length(v_prompt) > 2000 THEN
      RAISE EXCEPTION '评审要求长度不合法（最多2000字）' USING ERRCODE = '22023';
    END IF;
    v_prompt := NULLIF(v_prompt, '');
  END IF;

  UPDATE public.merchant_wecom_settings
  SET archive_secret = CASE WHEN v_secret IS NOT NULL THEN NULLIF(v_secret, '') ELSE archive_secret END,
      archive_private_keys = v_keys,
      archive_enabled = v_enabled,
      archive_checked_at = now(),
      suggest_critic_enabled = COALESCE(p_critic_enabled, suggest_critic_enabled),
      suggest_critic_prompt = CASE WHEN p_critic_prompt IS NOT NULL THEN v_prompt ELSE suggest_critic_prompt END,
      updated_at = now()
  WHERE root_manager_id = v_root;

  RETURN jsonb_build_object('ok', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.save_wecom_pro_archive_config(text, jsonb, int, boolean, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_wecom_pro_archive_config(text, jsonb, int, boolean, boolean, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
