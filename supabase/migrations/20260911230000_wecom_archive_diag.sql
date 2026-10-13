-- ============================================================================
-- 企微会话存档 —— 链路诊断字段
--
-- 目标：商户在配置页/存档页能自助判断「配置是否生效、消息有没有进来」：
--   1. merchant_wecom_settings 增列 archive_collector_error：
--      采集器每轮拉取若出错（secret 失效 / 网络异常 / SDK 报错），随心跳回传，
--      正常轮次清空。用于区分「无新消息」与「拉取失败」。
--   2. get_wecom_pro_archive_config 增回：
--        collectorError —— 最近一轮采集错误（空=正常）
--        latestMessageAt —— 仓内最新消息时间（bigint 秒），配合自动刷新可看到消息实时进仓
-- ============================================================================

ALTER TABLE public.merchant_wecom_settings
  ADD COLUMN IF NOT EXISTS archive_collector_error text;

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
  IF NOT public.wecom_pro_module_open(v_root) THEN
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
