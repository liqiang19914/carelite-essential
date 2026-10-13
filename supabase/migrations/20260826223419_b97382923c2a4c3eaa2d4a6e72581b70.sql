-- 修正承接智能体语义：NULL=保持原值，空串=清空
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
    SET kf_open_kfid = COALESCE(NULLIF(EXCLUDED.kf_open_kfid, ''), merchant_wecom_settings.kf_open_kfid),
        kf_token = COALESCE(NULLIF(EXCLUDED.kf_token, ''), merchant_wecom_settings.kf_token),
        kf_aes_key = COALESCE(NULLIF(EXCLUDED.kf_aes_key, ''), merchant_wecom_settings.kf_aes_key),
        kf_mode = CASE
          WHEN NULLIF(v_mode, '') IS NULL THEN merchant_wecom_settings.kf_mode
          ELSE EXCLUDED.kf_mode
        END,
        kf_ai_agent_manager_id = CASE
          WHEN NOT v_agent_provided THEN merchant_wecom_settings.kf_ai_agent_manager_id
          ELSE v_agent
        END,
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