-- 审查修复（347-350）：微信客服协议对齐 sync_msg + 幂等/认领/清空语义
-- 1. 回调游标持久化：增量拉取微信客服消息
ALTER TABLE public.merchant_wecom_settings
  ADD COLUMN IF NOT EXISTS kf_sync_cursor text;

-- 2. 消息表：通用幂等键（事件消息无 msgid 也唯一）+ AI 认领标记
ALTER TABLE public.merchant_wecom_kf_messages
  ADD COLUMN IF NOT EXISTS dedupe_key text,
  ADD COLUMN IF NOT EXISTS ai_replied boolean NOT NULL DEFAULT false;

UPDATE public.merchant_wecom_kf_messages
SET dedupe_key = 'legacy:' || id::text
WHERE dedupe_key IS NULL OR dedupe_key = '';

ALTER TABLE public.merchant_wecom_kf_messages
  ALTER COLUMN dedupe_key SET NOT NULL;

DO $block$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'uq_kf_message_dedupe'
      AND conrelid = 'public.merchant_wecom_kf_messages'::regclass
  ) THEN
    ALTER TABLE public.merchant_wecom_kf_messages
      ADD CONSTRAINT uq_kf_message_dedupe UNIQUE (conversation_id, dedupe_key);
  END IF;
END;
$block$;

-- 3. 微信客服配置保存：NULL=保持原值，空串=清空（含承接智能体）
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
  v_agent_provided boolean;
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

  v_agent_provided := p_kf_ai_agent_manager_id IS NOT NULL;
  v_agent := NULL;
  IF v_agent_provided AND btrim(p_kf_ai_agent_manager_id) <> '' THEN
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
    SET kf_open_kfid = CASE
          WHEN p_kf_open_kfid IS NULL THEN merchant_wecom_settings.kf_open_kfid
          ELSE EXCLUDED.kf_open_kfid
        END,
        kf_token = CASE
          WHEN p_kf_token IS NULL THEN merchant_wecom_settings.kf_token
          ELSE EXCLUDED.kf_token
        END,
        kf_aes_key = CASE
          WHEN p_kf_aes_key IS NULL THEN merchant_wecom_settings.kf_aes_key
          ELSE EXCLUDED.kf_aes_key
        END,
        kf_mode = CASE
          WHEN NULLIF(v_mode, '') IS NULL THEN merchant_wecom_settings.kf_mode
          ELSE EXCLUDED.kf_mode
        END,
        kf_ai_agent_manager_id = CASE
          WHEN NOT v_agent_provided THEN merchant_wecom_settings.kf_ai_agent_manager_id
          ELSE v_agent
        END,
        kf_verified_at = CASE
          WHEN p_kf_open_kfid IS NOT NULL
                AND NULLIF(EXCLUDED.kf_open_kfid, '') IS DISTINCT FROM merchant_wecom_settings.kf_open_kfid
            OR (p_kf_token IS NOT NULL
                AND NULLIF(EXCLUDED.kf_token, '') IS DISTINCT FROM merchant_wecom_settings.kf_token)
            OR (p_kf_aes_key IS NOT NULL
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

-- 4. 台账：企微回调行从商户根全集出发，未建设置行的商户也出现
CREATE OR REPLACE FUNCTION public.admin_list_all_domains()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT COALESCE(public.is_admin(auth.uid()), false) THEN
    RAISE EXCEPTION '仅超级管理员可执行此操作' USING ERRCODE = '42501';
  END IF;

  RETURN (
    WITH ledger AS (
      SELECT
        'site:' || d.id::text AS row_key,
        'site'::text AS source_type,
        d.id::text AS source_id,
        d.root_manager_id,
        d.hostname,
        COALESCE(NULLIF(m.business_name,''), NULLIF(m.company_name,''), m.id::text) AS merchant_name,
        d.status,
        d.created_at AS sort_at,
        d.verified_at,
        NULL::timestamptz AS last_callback_at,
        NULL::boolean AS has_single_chat_secret,
        NULL::boolean AS has_single_chat_token,
        NULL::boolean AS has_single_chat_aes_key,
        NULL::text AS single_chat_corp_id,
        NULL::text AS single_chat_agent_id,
        NULL::text AS callback_proxy_status,
        NULL::text AS callback_proxy_reason,
        NULL::timestamptz AS callback_proxy_checked_at,
        NULL::text AS callback_proxy_checked_domain,
        NULL::text AS kf_open_kfid,
        NULL::text AS kf_mode,
        NULL::uuid AS kf_ai_agent_manager_id
      FROM public.manager_domains d
      JOIN public.managers m ON m.id = d.root_manager_id
      UNION ALL
      SELECT
        CASE
          WHEN s.id IS NOT NULL THEN 'wecom:' || s.id::text
          ELSE 'wecom:root:' || m.id::text
        END AS row_key,
        'wecom'::text AS source_type,
        COALESCE(s.id::text, m.id::text) AS source_id,
        m.id AS root_manager_id,
        s.callback_domain AS hostname,
        COALESCE(NULLIF(m.business_name,''), NULLIF(m.company_name,''), m.id::text) AS merchant_name,
        NULL::text AS status,
        COALESCE(s.created_at, m.created_at) AS sort_at,
        s.single_chat_callback_verified_at AS verified_at,
        s.single_chat_last_callback_at AS last_callback_at,
        (s.single_chat_secret IS NOT NULL AND s.single_chat_secret <> '') AS has_single_chat_secret,
        (s.single_chat_token IS NOT NULL AND s.single_chat_token <> '') AS has_single_chat_token,
        (s.single_chat_aes_key IS NOT NULL AND s.single_chat_aes_key <> '') AS has_single_chat_aes_key,
        s.single_chat_corp_id,
        s.single_chat_agent_id,
        s.callback_proxy_status,
        s.callback_proxy_reason,
        s.callback_proxy_checked_at,
        s.callback_proxy_checked_domain,
        s.kf_open_kfid,
        s.kf_mode,
        s.kf_ai_agent_manager_id
      FROM public.managers m
      JOIN public.profiles p ON p.id = m.id
      LEFT JOIN public.enterprises e ON e.id = p.enterprise_id
      LEFT JOIN public.merchant_wecom_settings s ON s.root_manager_id = m.id
      WHERE p.role = 'manager'
        AND COALESCE(m.is_system_default, false) = false
        AND COALESCE(m.is_platform_root, false) = false
        AND (
          (e.id IS NOT NULL AND e.status = 'active' AND e.owner_profile_id = m.id)
          OR (e.id IS NULL AND p.parent_manager_id IS NULL)
        )
    )
    SELECT COALESCE(
      jsonb_agg(to_jsonb(ledger) ORDER BY ledger.sort_at DESC NULLS LAST, ledger.row_key),
      '[]'::jsonb
    )
    FROM ledger
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_all_domains() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_all_domains() TO authenticated;