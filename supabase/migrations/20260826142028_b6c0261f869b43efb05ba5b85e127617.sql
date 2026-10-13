-- 收口：企业微信配置仅「调用者本人是商户根」可读写；员工即使同企业也拿不到。

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
      (single_chat_aes_key IS NOT NULL AND single_chat_aes_key <> '') AS has_single_chat_aes_key,
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
        single_chat_corp_id = EXCLUDED.single_chat_corp_id,
        single_chat_agent_id = EXCLUDED.single_chat_agent_id,
        single_chat_secret = COALESCE(NULLIF(EXCLUDED.single_chat_secret, ''), merchant_wecom_settings.single_chat_secret),
        single_chat_token = COALESCE(NULLIF(EXCLUDED.single_chat_token, ''), merchant_wecom_settings.single_chat_token),
        single_chat_aes_key = COALESCE(NULLIF(EXCLUDED.single_chat_aes_key, ''), merchant_wecom_settings.single_chat_aes_key),
        single_chat_enabled = false,
        updated_at = now();

  RETURN public.get_merchant_wecom_config();
END;
$function$;

REVOKE ALL ON FUNCTION public.save_merchant_wecom_settings(boolean, text, text, uuid, text, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_merchant_wecom_settings(boolean, text, text, uuid, text, text, text, text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.save_merchant_wecom_group(
  p_name text,
  p_webhook_url text,
  p_enabled boolean DEFAULT true,
  p_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_name text;
  v_webhook text;
  v_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_merchant_root(auth.uid()) THEN
    RAISE EXCEPTION '仅企业负责人可配置企业微信' USING ERRCODE = '42501';
  END IF;
  v_root := auth.uid();

  v_name := btrim(COALESCE(p_name, ''));
  IF char_length(v_name) < 1 OR char_length(v_name) > 50 THEN
    RAISE EXCEPTION '群名称需在 1-50 个字符之间' USING ERRCODE = 'P0002';
  END IF;

  v_webhook := btrim(COALESCE(p_webhook_url, ''));
  IF v_webhook !~ '^https://qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?key=[A-Za-z0-9\-_]{16,128}$' THEN
    RAISE EXCEPTION '请粘贴企业微信群机器人的完整 Webhook 地址（以 https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key= 开头）' USING ERRCODE = 'P0002';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.merchant_wecom_groups (root_manager_id, name, webhook_url, enabled, public_token)
    VALUES (v_root, v_name, v_webhook, COALESCE(p_enabled, true), gen_random_uuid()::text)
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.merchant_wecom_groups
       SET name = v_name,
           webhook_url = v_webhook,
           enabled = COALESCE(p_enabled, true),
           consecutive_failures = 0,
           disabled_reason = NULL,
           updated_at = now()
     WHERE id = p_id AND root_manager_id = v_root
     RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      RAISE EXCEPTION '该群不存在或无权操作' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  RETURN jsonb_build_object('id', v_id, 'name', v_name);
END;
$function$;

REVOKE ALL ON FUNCTION public.save_merchant_wecom_group(text, text, boolean, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_merchant_wecom_group(text, text, boolean, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.delete_merchant_wecom_group(p_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_deleted uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_merchant_root(auth.uid()) THEN
    RAISE EXCEPTION '仅企业负责人可配置企业微信' USING ERRCODE = '42501';
  END IF;
  v_root := auth.uid();

  DELETE FROM public.merchant_wecom_groups
   WHERE id = p_id AND root_manager_id = v_root
  RETURNING id INTO v_deleted;

  RETURN v_deleted IS NOT NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_merchant_wecom_group(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_merchant_wecom_group(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.save_merchant_wecom_tips(p_tips jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_arr jsonb;
  v_item record;
  v_count int := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_merchant_root(auth.uid()) THEN
    RAISE EXCEPTION '仅企业负责人可配置企业微信' USING ERRCODE = '42501';
  END IF;
  v_root := auth.uid();

  v_arr := COALESCE(p_tips, '[]'::jsonb);
  IF jsonb_typeof(v_arr) <> 'array' THEN
    RAISE EXCEPTION '小贴士格式不正确' USING ERRCODE = 'P0002';
  END IF;
  IF jsonb_array_length(v_arr) > 30 THEN
    RAISE EXCEPTION '健康小贴士最多 30 条' USING ERRCODE = 'P0002';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_arr)
  LOOP
    IF char_length(btrim(COALESCE(v_item.value->>'content', ''))) NOT BETWEEN 1 AND 600 THEN
      RAISE EXCEPTION '每条小贴士需在 1-600 字之间' USING ERRCODE = 'P0002';
    END IF;
  END LOOP;

  DELETE FROM public.merchant_wecom_tips WHERE root_manager_id = v_root;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_arr) WITH ORDINALITY AS t(value, ord)
  LOOP
    INSERT INTO public.merchant_wecom_tips (root_manager_id, content, sort_order)
    VALUES (v_root, btrim(COALESCE(v_item.value->>'content', '')), v_item.ord);
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object('count', v_count);
END;
$function$;

REVOKE ALL ON FUNCTION public.save_merchant_wecom_tips(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_merchant_wecom_tips(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.list_merchant_wecom_push_logs(
  p_group_id uuid DEFAULT NULL,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_items jsonb;
  v_total int;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_merchant_root(auth.uid()) THEN
    RETURN NULL::jsonb;
  END IF;
  v_root := auth.uid();

  IF p_group_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.merchant_wecom_groups
    WHERE id = p_group_id AND root_manager_id = v_root
  ) THEN
    RAISE EXCEPTION '该群不存在或无权操作' USING ERRCODE = 'P0002';
  END IF;

  SELECT count(*) INTO v_total
  FROM public.merchant_wecom_push_logs
  WHERE root_manager_id = v_root
    AND (p_group_id IS NULL OR group_id = p_group_id);

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC), '[]'::jsonb) INTO v_items
  FROM (
    SELECT
      l.id, l.group_id, g.name AS group_name, l.push_type, l.success,
      l.status_code, l.error_code, l.error_detail, l.content_preview, l.created_at
    FROM public.merchant_wecom_push_logs l
    LEFT JOIN public.merchant_wecom_groups g ON g.id = l.group_id
    WHERE l.root_manager_id = v_root
      AND (p_group_id IS NULL OR l.group_id = p_group_id)
    ORDER BY l.created_at DESC
    LIMIT GREATEST(LEAST(p_limit, 100), 1)
    OFFSET GREATEST(p_offset, 0)
  ) t;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_merchant_wecom_push_logs(uuid, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_merchant_wecom_push_logs(uuid, int, int) TO authenticated;