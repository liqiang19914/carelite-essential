-- ============================================================================
-- OEM 管理师白牌品牌定制：
--  1) 在 manager_miniprograms 表增加 7 列品牌字段
--  2) 更新 _manager_miniprograms_apply_config 白名单 applier（新增 CASE 分支）
--  3) 更新 get_manager_oem_config 返回体（默认与命中两个分支都补上 7 字段）
--  4) 更新 admin_list_manager_oem_configs 摘要（追加 brand_name）
-- ============================================================================

-- ─── 1. Add branding columns ───────────────────────────────────────────────

ALTER TABLE public.manager_miniprograms
  ADD COLUMN IF NOT EXISTS brand_name         text,
  ADD COLUMN IF NOT EXISTS brand_logo_url     text,
  ADD COLUMN IF NOT EXISTS ai_agent_name      text,
  ADD COLUMN IF NOT EXISTS brand_full_name    text,
  ADD COLUMN IF NOT EXISTS privacy_policy_url text,
  ADD COLUMN IF NOT EXISTS terms_url          text,
  ADD COLUMN IF NOT EXISTS support_contact    text;

COMMENT ON COLUMN public.manager_miniprograms.brand_name         IS 'OEM 对外品牌名，替换 UI 里所有「小凯同学」文字露出';
COMMENT ON COLUMN public.manager_miniprograms.brand_logo_url     IS 'OEM Logo URL（走 s3-pre-sign-url 上传到 OSS 拿到的 https URL）';
COMMENT ON COLUMN public.manager_miniprograms.ai_agent_name      IS 'AI 助手显示名，如「小张同学」；空则 fallback brand_name → 小凯同学';
COMMENT ON COLUMN public.manager_miniprograms.brand_full_name    IS '公司主体名 / 版权页脚署名';
COMMENT ON COLUMN public.manager_miniprograms.privacy_policy_url IS '外部隐私政策 URL，空则用平台内置模板 + 品牌占位替换';
COMMENT ON COLUMN public.manager_miniprograms.terms_url          IS '外部用户协议 URL，同上';
COMMENT ON COLUMN public.manager_miniprograms.support_contact    IS '客服联系方式（电话 / 微信 / 邮箱）';

-- ─── 2. Update whitelist applier — 追加 7 个 CASE 分支 ─────────────────────

CREATE OR REPLACE FUNCTION public._manager_miniprograms_apply_config(
  p_manager_id uuid,
  p_config jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_app_id text;
BEGIN
  -- Normalize app_id once for unique-conflict messaging
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
    -- 新增 7 个品牌字段
    brand_name         = CASE WHEN p_config ? 'brand_name'         THEN NULLIF(btrim(p_config->>'brand_name'), '')         ELSE brand_name END,
    brand_logo_url     = CASE WHEN p_config ? 'brand_logo_url'     THEN NULLIF(btrim(p_config->>'brand_logo_url'), '')     ELSE brand_logo_url END,
    ai_agent_name      = CASE WHEN p_config ? 'ai_agent_name'      THEN NULLIF(btrim(p_config->>'ai_agent_name'), '')      ELSE ai_agent_name END,
    brand_full_name    = CASE WHEN p_config ? 'brand_full_name'    THEN NULLIF(btrim(p_config->>'brand_full_name'), '')    ELSE brand_full_name END,
    privacy_policy_url = CASE WHEN p_config ? 'privacy_policy_url' THEN NULLIF(btrim(p_config->>'privacy_policy_url'), '') ELSE privacy_policy_url END,
    terms_url          = CASE WHEN p_config ? 'terms_url'          THEN NULLIF(btrim(p_config->>'terms_url'), '')          ELSE terms_url END,
    support_contact    = CASE WHEN p_config ? 'support_contact'    THEN NULLIF(btrim(p_config->>'support_contact'), '')    ELSE support_contact END,
    updated_by      = auth.uid()
  WHERE manager_id = p_manager_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public._manager_miniprograms_apply_config(uuid, jsonb) FROM PUBLIC, authenticated, anon;

-- ─── 3. Update get_manager_oem_config — 返回体补齐 7 字段 ──────────────────

CREATE OR REPLACE FUNCTION public.get_manager_oem_config(p_manager_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

REVOKE EXECUTE ON FUNCTION public.get_manager_oem_config(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_manager_oem_config(uuid) TO authenticated;

-- ─── 4. Update admin_list_manager_oem_configs — 摘要追加 brand_name ────────

CREATE OR REPLACE FUNCTION public.admin_list_manager_oem_configs()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '仅平台管理员可访问' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(t) ORDER BY t.created_at DESC), '[]'::jsonb)
    INTO v_result
  FROM (
    SELECT
      m.id                                 AS manager_id,
      p.nickname                           AS manager_nickname,
      p.phone                              AS manager_phone,
      m.certification_status               AS certification_status,
      COALESCE(mm.is_enabled, false)       AS is_enabled,
      mm.app_id                            AS app_id,
      (mm.app_secret IS NOT NULL AND length(mm.app_secret) > 0) AS has_app_secret,
      (mm.upload_key IS NOT NULL AND length(mm.upload_key) > 0) AS has_upload_key,
      mm.business_domain                   AS business_domain,
      mm.target_path                       AS target_path,
      mm.app_name                          AS app_name,
      mm.brand_name                        AS brand_name,
      mm.brand_logo_url                    AS brand_logo_url,
      mm.updated_at                        AS updated_at,
      mm.updated_by                        AS updated_by_id,
      up.nickname                          AS updated_by_nickname,
      m.created_at                         AS created_at
    FROM public.managers m
    JOIN public.profiles p ON p.id = m.id
    LEFT JOIN public.manager_miniprograms mm ON mm.manager_id = m.id
    LEFT JOIN public.profiles up ON up.id = mm.updated_by
  ) t;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_list_manager_oem_configs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_manager_oem_configs() TO authenticated;