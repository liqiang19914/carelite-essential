-- ── 1. 微信客服三字段 ─────────────────────────────────────────────
ALTER TABLE public.merchant_consult_settings
  ADD COLUMN IF NOT EXISTS wecom_kf_url text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS wecom_kf_corp_id text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS wecom_kf_enabled boolean NOT NULL DEFAULT false;

COMMENT ON TABLE public.merchant_consult_settings IS
  '商户级商城咨询配置：channels ∈ ai/miniapp_contact/wecom_qr/wecom_acquisition/wecom_kf，可多选组合。ai_manager_id 是承接商城咨询的本企业健管师。';

-- ── 2. save 9 参新签名（旧 6 参签名保留共存，待前端全部切换后再清理）──
CREATE OR REPLACE FUNCTION public.save_merchant_consult_settings(
  p_channels TEXT[],
  p_ai_manager_id UUID,
  p_human_handoff_enabled BOOLEAN,
  p_wecom_qr_url TEXT,
  p_wecom_acquisition_url TEXT,
  p_miniapp_contact_enabled BOOLEAN,
  p_wecom_kf_url TEXT,
  p_wecom_kf_corp_id TEXT,
  p_wecom_kf_enabled BOOLEAN
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_channel TEXT;
  v_ok BOOLEAN;
  v_kf_url TEXT;
  v_kf_corp TEXT;
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
      IF v_channel NOT IN ('ai','miniapp_contact','wecom_qr','wecom_acquisition','wecom_kf') THEN
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

  v_kf_url := btrim(COALESCE(p_wecom_kf_url, ''));
  v_kf_corp := btrim(COALESCE(p_wecom_kf_corp_id, ''));
  IF char_length(v_kf_url) > 2000 THEN
    RAISE EXCEPTION '微信客服链接过长' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_kf_corp) > 64 THEN
    RAISE EXCEPTION '企业 ID 过长' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(p_wecom_kf_enabled, false) THEN
    IF v_kf_url = '' OR v_kf_corp = '' THEN
      RAISE EXCEPTION '启用微信客服前请填写客服链接和企业 ID' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF v_kf_url <> '' AND v_kf_url NOT LIKE 'https://work.weixin.qq.com/kfid/%' THEN
    RAISE EXCEPTION '微信客服链接格式不正确' USING ERRCODE = '22023';
  END IF;
  IF v_kf_corp <> '' AND v_kf_corp !~ '^ww[0-9a-zA-Z_-]{6,64}$' THEN
    RAISE EXCEPTION '企业 ID 格式不正确（应为 ww 开头的企业微信企业 ID）' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.merchant_consult_settings (
    root_manager_id, channels, ai_manager_id, human_handoff_enabled,
    wecom_qr_url, wecom_acquisition_url, miniapp_contact_enabled,
    wecom_kf_url, wecom_kf_corp_id, wecom_kf_enabled
  ) VALUES (
    v_root, COALESCE(p_channels, '{}'), p_ai_manager_id,
    COALESCE(p_human_handoff_enabled, false),
    btrim(COALESCE(p_wecom_qr_url, '')), btrim(COALESCE(p_wecom_acquisition_url, '')),
    COALESCE(p_miniapp_contact_enabled, false),
    v_kf_url, v_kf_corp, COALESCE(p_wecom_kf_enabled, false)
  )
  ON CONFLICT (root_manager_id) DO UPDATE SET
    channels = COALESCE(EXCLUDED.channels, merchant_consult_settings.channels),
    ai_manager_id = CASE WHEN p_ai_manager_id IS NULL THEN merchant_consult_settings.ai_manager_id ELSE EXCLUDED.ai_manager_id END,
    human_handoff_enabled = COALESCE(EXCLUDED.human_handoff_enabled, false),
    wecom_qr_url = CASE WHEN p_wecom_qr_url IS NULL THEN merchant_consult_settings.wecom_qr_url ELSE EXCLUDED.wecom_qr_url END,
    wecom_acquisition_url = CASE WHEN p_wecom_acquisition_url IS NULL THEN merchant_consult_settings.wecom_acquisition_url ELSE EXCLUDED.wecom_acquisition_url END,
    miniapp_contact_enabled = COALESCE(EXCLUDED.miniapp_contact_enabled, false),
    wecom_kf_url = EXCLUDED.wecom_kf_url,
    wecom_kf_corp_id = EXCLUDED.wecom_kf_corp_id,
    wecom_kf_enabled = EXCLUDED.wecom_kf_enabled,
    updated_at = now();

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.save_merchant_consult_settings(TEXT[], UUID, BOOLEAN, TEXT, TEXT, BOOLEAN, TEXT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_merchant_consult_settings(TEXT[], UUID, BOOLEAN, TEXT, TEXT, BOOLEAN, TEXT, TEXT, BOOLEAN) TO authenticated;

-- ── 3. 商户读取接口返回微信客服配置 ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_merchant_consult_settings()
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_row public.merchant_consult_settings%ROWTYPE;
  v_ai_name TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_row FROM public.merchant_consult_settings WHERE root_manager_id = v_root;
  IF NOT FOUND THEN
    RETURN json_build_object('configured', false);
  END IF;

  SELECT m.partner_card_display_name INTO v_ai_name
  FROM public.managers m WHERE m.id = v_row.ai_manager_id;

  RETURN json_build_object(
    'configured', true,
    'channels', v_row.channels,
    'ai_manager_id', v_row.ai_manager_id,
    'ai_manager_name', COALESCE(v_ai_name, ''),
    'human_handoff_enabled', v_row.human_handoff_enabled,
    'wecom_qr_url', v_row.wecom_qr_url,
    'wecom_acquisition_url', v_row.wecom_acquisition_url,
    'miniapp_contact_enabled', v_row.miniapp_contact_enabled,
    'wecom_kf_url', v_row.wecom_kf_url,
    'wecom_kf_corp_id', v_row.wecom_kf_corp_id,
    'wecom_kf_enabled', v_row.wecom_kf_enabled,
    'updated_at', v_row.updated_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_merchant_consult_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_merchant_consult_settings() TO authenticated;

-- ── 4. 公开读取接口返回微信客服配置 ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_public_merchant_consult_settings(p_root_manager_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_row public.merchant_consult_settings%ROWTYPE;
  v_ai_short TEXT;
  v_ai_name TEXT;
  v_ai_ready BOOLEAN;
BEGIN
  IF p_root_manager_id IS NULL THEN
    RETURN json_build_object('configured', false);
  END IF;
  SELECT * INTO v_row FROM public.merchant_consult_settings WHERE root_manager_id = p_root_manager_id;
  IF NOT FOUND THEN
    RETURN json_build_object('configured', false);
  END IF;

  v_ai_ready := false;
  IF v_row.ai_manager_id IS NOT NULL AND v_row.channels @> ARRAY['ai'] THEN
    SELECT m.short_code, m.partner_card_display_name
      INTO v_ai_short, v_ai_name
    FROM public.managers m WHERE m.id = v_row.ai_manager_id;
    IF v_ai_short IS NOT NULL THEN
      v_ai_ready := true;
    END IF;
  END IF;

  RETURN json_build_object(
    'configured', true,
    'channels', v_row.channels,
    'ai_manager_id', v_row.ai_manager_id,
    'ai_manager_short_code', COALESCE(v_ai_short, ''),
    'ai_manager_name', COALESCE(v_ai_name, ''),
    'ai_ready', v_ai_ready,
    'human_handoff_enabled', v_row.human_handoff_enabled,
    'wecom_qr_url', v_row.wecom_qr_url,
    'wecom_acquisition_url', v_row.wecom_acquisition_url,
    'miniapp_contact_enabled', v_row.miniapp_contact_enabled,
    'wecom_kf_url', v_row.wecom_kf_url,
    'wecom_kf_corp_id', v_row.wecom_kf_corp_id,
    'wecom_kf_enabled', v_row.wecom_kf_enabled
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_merchant_consult_settings(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_merchant_consult_settings(UUID) TO anon, authenticated;

-- ── 5. 店级可见性判定：与 get_storefront_product_detail 逐行一致 ───
CREATE OR REPLACE FUNCTION public.can_view_storefront_product(
  p_product_id uuid,
  p_shop_root uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_product public.products%ROWTYPE;
  v_root    uuid;
BEGIN
  IF p_product_id IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT * INTO v_product
  FROM public.products
  WHERE id = p_product_id AND status = 'active';
  IF v_product.id IS NULL THEN
    RETURN FALSE;
  END IF;

  IF p_shop_root IS NOT NULL THEN
    v_root := public.get_enterprise_root_manager_id(p_shop_root);
    IF v_root IS NULL THEN
      RETURN FALSE;
    END IF;
  END IF;

  IF v_product.source_type = 'platform' AND v_root IS NOT NULL THEN
    RETURN FALSE;
  END IF;

  IF v_product.source_type = 'manager' THEN
    IF v_root IS NULL
       OR v_product.owner_manager_id IS NULL
       OR public.get_enterprise_root_manager_id(v_product.owner_manager_id) IS DISTINCT FROM v_root THEN
      RETURN FALSE;
    END IF;
  END IF;

  RETURN TRUE;
END;
$function$;

REVOKE ALL ON FUNCTION public.can_view_storefront_product(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_view_storefront_product(uuid, uuid) TO anon, authenticated, service_role;