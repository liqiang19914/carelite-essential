-- 小贴士排序还原为原始口径（sort_order, id），与 340 版一致。
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