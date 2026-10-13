CREATE OR REPLACE FUNCTION public.save_merchant_consult_settings(p_channels text[], p_ai_manager_id uuid, p_human_handoff_enabled boolean, p_wecom_qr_url text, p_wecom_acquisition_url text, p_miniapp_contact_enabled boolean)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_channel TEXT;
  v_ok BOOLEAN;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '只有商户账号可以配置咨询方式' USING ERRCODE = '42501';
  END IF;

  v_ok := true;
  IF p_channels IS NOT NULL THEN
    FOREACH v_channel IN ARRAY p_channels LOOP
      IF v_channel NOT IN ('ai','miniapp_contact','wecom_qr','wecom_acquisition') THEN
        v_ok := false;
      END IF;
    END LOOP;
  END IF;
  IF NOT v_ok THEN
    RAISE EXCEPTION '咨询方式配置不合法' USING ERRCODE = '22023';
  END IF;

  IF p_ai_manager_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.managers m
      WHERE m.id = p_ai_manager_id
        AND public.get_enterprise_root_manager_id(m.id) = v_root
    ) THEN
      RAISE EXCEPTION '只能选择本企业的健管师来回答商城咨询' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF char_length(COALESCE(p_wecom_qr_url, '')) > 2000 THEN
    RAISE EXCEPTION '企微二维码链接过长' USING ERRCODE = '22023';
  END IF;
  IF char_length(COALESCE(p_wecom_acquisition_url, '')) > 2000 THEN
    RAISE EXCEPTION '获客助手链接过长' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.merchant_consult_settings (
    root_manager_id, channels, ai_manager_id, human_handoff_enabled,
    wecom_qr_url, wecom_acquisition_url, miniapp_contact_enabled
  ) VALUES (
    v_root, COALESCE(p_channels, '{}'), p_ai_manager_id,
    COALESCE(p_human_handoff_enabled, false),
    btrim(COALESCE(p_wecom_qr_url, '')), btrim(COALESCE(p_wecom_acquisition_url, '')),
    COALESCE(p_miniapp_contact_enabled, false)
  )
  ON CONFLICT (root_manager_id) DO UPDATE SET
    channels = COALESCE(EXCLUDED.channels, merchant_consult_settings.channels),
    ai_manager_id = EXCLUDED.ai_manager_id,
    human_handoff_enabled = COALESCE(EXCLUDED.human_handoff_enabled, false),
    wecom_qr_url = EXCLUDED.wecom_qr_url,
    wecom_acquisition_url = EXCLUDED.wecom_acquisition_url,
    miniapp_contact_enabled = COALESCE(EXCLUDED.miniapp_contact_enabled, false),
    updated_at = now();

  RETURN json_build_object('success', true);
END;
$function$;