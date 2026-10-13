-- 反向代理台账：探测快照列 + 微信客服接待列
ALTER TABLE public.merchant_wecom_settings
  ADD COLUMN IF NOT EXISTS callback_proxy_status text,
  ADD COLUMN IF NOT EXISTS callback_proxy_reason text,
  ADD COLUMN IF NOT EXISTS callback_proxy_checked_at timestamptz,
  ADD COLUMN IF NOT EXISTS callback_proxy_checked_domain text,
  ADD COLUMN IF NOT EXISTS kf_open_kfid text,
  ADD COLUMN IF NOT EXISTS kf_token text,
  ADD COLUMN IF NOT EXISTS kf_aes_key text,
  ADD COLUMN IF NOT EXISTS kf_mode text NOT NULL DEFAULT 'hybrid'
    CHECK (kf_mode IN ('human','ai','hybrid')),
  ADD COLUMN IF NOT EXISTS kf_ai_agent_manager_id uuid
    REFERENCES public.managers(id) ON DELETE SET NULL;

-- 回调保存接口升级：回调子域支持显式清空（NULL=保持原值、空串=清空）；
-- 企业号/AgentId/Secret/Token/AESKey/回调子域任一变化时清空企微验证时间与反代探测快照。
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
  v_domain_provided boolean;
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
  v_domain_provided := p_callback_domain IS NOT NULL;
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
        callback_domain = CASE
          WHEN v_domain_provided THEN EXCLUDED.callback_domain
          ELSE merchant_wecom_settings.callback_domain
        END,
        single_chat_callback_verified_at = CASE
          WHEN (NULLIF(EXCLUDED.single_chat_corp_id, '') IS NOT NULL
                AND NULLIF(EXCLUDED.single_chat_corp_id, '') IS DISTINCT FROM merchant_wecom_settings.single_chat_corp_id)
            OR (NULLIF(EXCLUDED.single_chat_agent_id, '') IS NOT NULL
                AND NULLIF(EXCLUDED.single_chat_agent_id, '') IS DISTINCT FROM merchant_wecom_settings.single_chat_agent_id)
            OR (NULLIF(EXCLUDED.single_chat_secret, '') IS NOT NULL
                AND NULLIF(EXCLUDED.single_chat_secret, '') IS DISTINCT FROM merchant_wecom_settings.single_chat_secret)
            OR (NULLIF(EXCLUDED.single_chat_token, '') IS NOT NULL
                AND NULLIF(EXCLUDED.single_chat_token, '') IS DISTINCT FROM merchant_wecom_settings.single_chat_token)
            OR (NULLIF(EXCLUDED.single_chat_aes_key, '') IS NOT NULL
                AND NULLIF(EXCLUDED.single_chat_aes_key, '') IS DISTINCT FROM merchant_wecom_settings.single_chat_aes_key)
            OR (v_domain_provided
                AND lower(btrim(COALESCE(p_callback_domain, ''))) IS DISTINCT FROM merchant_wecom_settings.callback_domain)
          THEN NULL
          ELSE merchant_wecom_settings.single_chat_callback_verified_at
        END,
        callback_proxy_status = CASE
          WHEN (v_domain_provided
                AND lower(btrim(COALESCE(p_callback_domain, ''))) IS DISTINCT FROM merchant_wecom_settings.callback_domain)
          THEN NULL
          ELSE merchant_wecom_settings.callback_proxy_status
        END,
        callback_proxy_reason = CASE
          WHEN (v_domain_provided
                AND lower(btrim(COALESCE(p_callback_domain, ''))) IS DISTINCT FROM merchant_wecom_settings.callback_domain)
          THEN NULL
          ELSE merchant_wecom_settings.callback_proxy_reason
        END,
        callback_proxy_checked_at = CASE
          WHEN (v_domain_provided
                AND lower(btrim(COALESCE(p_callback_domain, ''))) IS DISTINCT FROM merchant_wecom_settings.callback_domain)
          THEN NULL
          ELSE merchant_wecom_settings.callback_proxy_checked_at
        END,
        callback_proxy_checked_domain = CASE
          WHEN (v_domain_provided
                AND lower(btrim(COALESCE(p_callback_domain, ''))) IS DISTINCT FROM merchant_wecom_settings.callback_domain)
          THEN NULL
          ELSE merchant_wecom_settings.callback_proxy_checked_domain
        END,
        single_chat_enabled = false,
        updated_at = now();

  RETURN public.get_merchant_wecom_config();
END;
$function$;

REVOKE ALL ON FUNCTION public.save_merchant_wecom_callback(text, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_merchant_wecom_callback(text, text, text, text, text, text) TO authenticated;

-- 台账列表：商户自定义域名（site）与企微回调行（wecom）两类行 UNION
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
        'wecom:' || s.id::text AS row_key,
        'wecom'::text AS source_type,
        s.id::text AS source_id,
        s.root_manager_id,
        s.callback_domain AS hostname,
        COALESCE(NULLIF(m.business_name,''), NULLIF(m.company_name,''), m.id::text) AS merchant_name,
        NULL::text AS status,
        s.created_at AS sort_at,
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
      FROM public.merchant_wecom_settings s
      JOIN public.managers m ON m.id = s.root_manager_id
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

-- 平台管理员读取指定商户的企业微信全量明文配置（含密钥，仅超管可见）
CREATE OR REPLACE FUNCTION public.admin_get_merchant_wecom_full(p_root_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_row jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT COALESCE(public.is_admin(auth.uid()), false) THEN
    RAISE EXCEPTION '仅超级管理员可执行此操作' USING ERRCODE = '42501';
  END IF;
  IF p_root_manager_id IS NULL THEN
    RAISE EXCEPTION '缺少商户标识' USING ERRCODE = 'P0002';
  END IF;

  SELECT to_jsonb(r) INTO v_row
  FROM (
    SELECT
      s.root_manager_id,
      COALESCE(NULLIF(m.business_name,''), NULLIF(m.company_name,''), m.id::text) AS merchant_name,
      m.brand_slug,
      m.short_code,
      s.single_chat_corp_id,
      s.single_chat_agent_id,
      s.single_chat_secret,
      s.single_chat_token,
      s.single_chat_aes_key,
      s.callback_domain,
      s.single_chat_callback_verified_at,
      s.single_chat_last_callback_at,
      s.callback_proxy_status,
      s.callback_proxy_reason,
      s.callback_proxy_checked_at,
      s.callback_proxy_checked_domain,
      s.kf_open_kfid,
      s.kf_mode,
      s.kf_ai_agent_manager_id
    FROM public.merchant_wecom_settings s
    JOIN public.managers m ON m.id = s.root_manager_id
    WHERE s.root_manager_id = p_root_manager_id
  ) r;

  IF v_row IS NULL THEN
    RETURN jsonb_build_object('root_manager_id', p_root_manager_id, 'settings_exists', false);
  END IF;
  RETURN v_row || jsonb_build_object('settings_exists', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_get_merchant_wecom_full(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_get_merchant_wecom_full(uuid) TO authenticated;