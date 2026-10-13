-- 让 OEM 配置的写入 / 读取函数认识 brand_primary_color
CREATE OR REPLACE FUNCTION public._manager_miniprograms_apply_config(p_manager_id uuid, p_config jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_app_id text;
BEGIN
  IF p_config ? 'app_id' THEN
    v_app_id := NULLIF(btrim(p_config->>'app_id'), '');
    IF v_app_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.manager_miniprograms
      WHERE app_id = v_app_id AND manager_id <> p_manager_id
    ) THEN
      RAISE EXCEPTION 'AppID 已被其他管理师使用，请检查' USING ERRCODE = '23505';
    END IF;
  END IF;

  UPDATE public.manager_miniprograms
  SET
    app_name        = CASE WHEN p_config ? 'app_name'        THEN NULLIF(btrim(p_config->>'app_name'), '')        ELSE app_name END,
    app_id          = CASE WHEN p_config ? 'app_id'          THEN NULLIF(btrim(p_config->>'app_id'), '')          ELSE app_id END,
    app_secret      = CASE WHEN p_config ? 'app_secret'      THEN NULLIF(btrim(p_config->>'app_secret'), '')      ELSE app_secret END,
    original_id     = CASE WHEN p_config ? 'original_id'     THEN NULLIF(btrim(p_config->>'original_id'), '')     ELSE original_id END,
    upload_key      = CASE WHEN p_config ? 'upload_key'      THEN NULLIF(btrim(p_config->>'upload_key'), '')      ELSE upload_key END,
    version         = CASE WHEN p_config ? 'version'         THEN COALESCE(NULLIF(btrim(p_config->>'version'), ''), '1.0.0') ELSE version END,
    request_domain  = CASE WHEN p_config ? 'request_domain'  THEN NULLIF(btrim(p_config->>'request_domain'), '')  ELSE request_domain END,
    socket_domain   = CASE WHEN p_config ? 'socket_domain'   THEN NULLIF(btrim(p_config->>'socket_domain'), '')   ELSE socket_domain END,
    upload_domain   = CASE WHEN p_config ? 'upload_domain'   THEN NULLIF(btrim(p_config->>'upload_domain'), '')   ELSE upload_domain END,
    download_domain = CASE WHEN p_config ? 'download_domain' THEN NULLIF(btrim(p_config->>'download_domain'), '') ELSE download_domain END,
    udp_domain      = CASE WHEN p_config ? 'udp_domain'      THEN NULLIF(btrim(p_config->>'udp_domain'), '')      ELSE udp_domain END,
    business_domain = CASE WHEN p_config ? 'business_domain' THEN NULLIF(btrim(p_config->>'business_domain'), '') ELSE business_domain END,
    target_path     = CASE WHEN p_config ? 'target_path'     THEN COALESCE(
                                                              (
                                                                SELECT CASE
                                                                  WHEN tp LIKE '/%' THEN tp
                                                                  WHEN tp IS NULL OR tp = '' THEN '/login'
                                                                  ELSE '/' || tp
                                                                END
                                                                FROM (SELECT NULLIF(btrim(p_config->>'target_path'), '') AS tp) sub
                                                              ),
                                                              '/login'
                                                            )
                                                       ELSE target_path END,
    brand_name         = CASE WHEN p_config ? 'brand_name'         THEN NULLIF(btrim(p_config->>'brand_name'), '')         ELSE brand_name END,
    brand_logo_url     = CASE WHEN p_config ? 'brand_logo_url'     THEN NULLIF(btrim(p_config->>'brand_logo_url'), '')     ELSE brand_logo_url END,
    -- 主色：非法值直接落 NULL，绝不把任意字符串写进色值列（配合列上的 HEX CHECK 双保险）
    brand_primary_color = CASE WHEN p_config ? 'brand_primary_color' THEN (
                                 SELECT CASE
                                   WHEN c ~* '^#([0-9a-f]{3}|[0-9a-f]{6})$' THEN lower(c)
                                   ELSE NULL
                                 END
                                 FROM (SELECT NULLIF(btrim(p_config->>'brand_primary_color'), '') AS c) sub
                               )
                          ELSE brand_primary_color END,
    ai_agent_name      = CASE WHEN p_config ? 'ai_agent_name'      THEN NULLIF(btrim(p_config->>'ai_agent_name'), '')      ELSE ai_agent_name END,
    brand_full_name    = CASE WHEN p_config ? 'brand_full_name'    THEN NULLIF(btrim(p_config->>'brand_full_name'), '')    ELSE brand_full_name END,
    privacy_policy_url = CASE WHEN p_config ? 'privacy_policy_url' THEN NULLIF(btrim(p_config->>'privacy_policy_url'), '') ELSE privacy_policy_url END,
    terms_url          = CASE WHEN p_config ? 'terms_url'          THEN NULLIF(btrim(p_config->>'terms_url'), '')          ELSE terms_url END,
    support_contact    = CASE WHEN p_config ? 'support_contact'    THEN NULLIF(btrim(p_config->>'support_contact'), '')    ELSE support_contact END,
    updated_by      = auth.uid()
  WHERE manager_id = p_manager_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_manager_oem_config(p_manager_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_target uuid;
  v_is_admin boolean;
  v_row public.manager_miniprograms%ROWTYPE;
  v_manager_nickname text;
  v_manager_phone text;
  v_manager_cert text;
  v_updated_by_nickname text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  v_is_admin := public.is_admin(v_caller);
  v_target := COALESCE(p_manager_id, v_caller);

  IF NOT v_is_admin AND v_target <> v_caller THEN
    RAISE EXCEPTION '无权访问该管理师配置' USING ERRCODE = '42501';
  END IF;

  SELECT p.nickname, p.phone, m.certification_status
    INTO v_manager_nickname, v_manager_phone, v_manager_cert
  FROM public.managers m
  JOIN public.profiles p ON p.id = m.id
  WHERE m.id = v_target;

  IF v_manager_nickname IS NULL THEN
    RAISE EXCEPTION '管理师不存在' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row FROM public.manager_miniprograms WHERE manager_id = v_target;

  IF v_row.manager_id IS NULL THEN
    RETURN jsonb_build_object(
      'manager_id',           v_target,
      'manager_nickname',     v_manager_nickname,
      'manager_phone',        v_manager_phone,
      'certification_status', v_manager_cert,
      'is_enabled',           false,
      'exists',               false,
      'app_name',             NULL,
      'app_id',               NULL,
      'app_secret',           NULL,
      'original_id',          NULL,
      'upload_key',           NULL,
      'version',              '1.0.0',
      'request_domain',       NULL,
      'socket_domain',        NULL,
      'upload_domain',        NULL,
      'download_domain',      NULL,
      'udp_domain',           NULL,
      'business_domain',      NULL,
      'target_path',          '/login',
      'brand_name',           NULL,
      'brand_logo_url',       NULL,
      'brand_primary_color',  NULL,
      'ai_agent_name',        NULL,
      'brand_full_name',      NULL,
      'privacy_policy_url',   NULL,
      'terms_url',            NULL,
      'support_contact',      NULL,
      'updated_at',           NULL,
      'updated_by_id',        NULL,
      'updated_by_nickname',  NULL
    );
  END IF;

  SELECT nickname INTO v_updated_by_nickname FROM public.profiles WHERE id = v_row.updated_by;

  RETURN jsonb_build_object(
    'manager_id',           v_row.manager_id,
    'manager_nickname',     v_manager_nickname,
    'manager_phone',        v_manager_phone,
    'certification_status', v_manager_cert,
    'is_enabled',           v_row.is_enabled,
    'exists',               true,
    'app_name',             v_row.app_name,
    'app_id',               v_row.app_id,
    'app_secret',           v_row.app_secret,
    'original_id',          v_row.original_id,
    'upload_key',           v_row.upload_key,
    'version',              v_row.version,
    'request_domain',       v_row.request_domain,
    'socket_domain',        v_row.socket_domain,
    'upload_domain',        v_row.upload_domain,
    'download_domain',      v_row.download_domain,
    'udp_domain',           v_row.udp_domain,
    'business_domain',      v_row.business_domain,
    'target_path',          v_row.target_path,
    'brand_name',           v_row.brand_name,
    'brand_logo_url',       v_row.brand_logo_url,
    'brand_primary_color',  v_row.brand_primary_color,
    'ai_agent_name',        v_row.ai_agent_name,
    'brand_full_name',      v_row.brand_full_name,
    'privacy_policy_url',   v_row.privacy_policy_url,
    'terms_url',            v_row.terms_url,
    'support_contact',      v_row.support_contact,
    'updated_at',           v_row.updated_at,
    'updated_by_id',        v_row.updated_by,
    'updated_by_nickname',  v_updated_by_nickname
  );
END;
$function$;