-- ================================================================
-- 数字人视频「验证并绑定」MVP：新增 7 字段 + 防篡改触发器 + 更新 RPC
-- ================================================================

-- 1. 新增 7 个规范化绑定字段
-- 老列 digital_persona_video_url 保留但废弃：不再读、不再写、不迁移历史值
ALTER TABLE public.managers
  ADD COLUMN IF NOT EXISTS digital_persona_source_platform TEXT,
  ADD COLUMN IF NOT EXISTS digital_persona_source_asset_id TEXT,
  ADD COLUMN IF NOT EXISTS digital_persona_playback_url    TEXT,
  ADD COLUMN IF NOT EXISTS digital_persona_format          TEXT,
  ADD COLUMN IF NOT EXISTS digital_persona_status          TEXT,
  ADD COLUMN IF NOT EXISTS digital_persona_verified_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS digital_persona_last_error      TEXT;

COMMENT ON COLUMN public.managers.digital_persona_video_url IS
  'DEPRECATED 2026-07-22：本列保留用于历史数据但已不参与任何读写；新流程走 digital_persona_playback_url + 状态字段。';

-- 2. 单字段 CHECK 约束
ALTER TABLE public.managers
  DROP CONSTRAINT IF EXISTS managers_dp_source_platform_check;
ALTER TABLE public.managers
  ADD CONSTRAINT managers_dp_source_platform_check
  CHECK (digital_persona_source_platform IS NULL
         OR digital_persona_source_platform IN ('kaitong_aip'));

ALTER TABLE public.managers
  DROP CONSTRAINT IF EXISTS managers_dp_format_check;
ALTER TABLE public.managers
  ADD CONSTRAINT managers_dp_format_check
  CHECK (digital_persona_format IS NULL
         OR digital_persona_format IN ('mp4', 'm3u8'));

ALTER TABLE public.managers
  DROP CONSTRAINT IF EXISTS managers_dp_status_check;
ALTER TABLE public.managers
  ADD CONSTRAINT managers_dp_status_check
  CHECK (digital_persona_status IS NULL
         OR digital_persona_status IN ('active', 'revoked', 'unavailable', 'error'));

ALTER TABLE public.managers
  DROP CONSTRAINT IF EXISTS managers_dp_playback_url_https_check;
ALTER TABLE public.managers
  ADD CONSTRAINT managers_dp_playback_url_https_check
  CHECK (digital_persona_playback_url IS NULL
         OR digital_persona_playback_url ~ '^https://');

-- 3. 跨字段一致性：status='active' ⇒ 平台/assetId/playback_url/format/verified_at 全非空
ALTER TABLE public.managers
  DROP CONSTRAINT IF EXISTS managers_dp_active_fields_check;
ALTER TABLE public.managers
  ADD CONSTRAINT managers_dp_active_fields_check
  CHECK (
    digital_persona_status IS DISTINCT FROM 'active'
    OR (
      digital_persona_source_platform IS NOT NULL
      AND digital_persona_source_asset_id IS NOT NULL
      AND digital_persona_playback_url IS NOT NULL
      AND digital_persona_format IS NOT NULL
      AND digital_persona_verified_at IS NOT NULL
    )
  );

-- 4. 防篡改触发器：authenticated 客户端不能直接改这 7 字段，只有 service_role 可以写
CREATE OR REPLACE FUNCTION public.protect_digital_persona_binding()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_caller_role TEXT := current_setting('request.jwt.claim.role', true);
  v_changed BOOLEAN := FALSE;
BEGIN
  -- service_role（EF 用）无条件放行
  IF v_caller_role = 'service_role' THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- 新增行时若 7 字段非空则拒绝（正常路径下前端不会同时写这些字段；只有恶意构造才会命中）
    IF NEW.digital_persona_source_platform IS NOT NULL
       OR NEW.digital_persona_source_asset_id IS NOT NULL
       OR NEW.digital_persona_playback_url IS NOT NULL
       OR NEW.digital_persona_format IS NOT NULL
       OR NEW.digital_persona_status IS NOT NULL
       OR NEW.digital_persona_verified_at IS NOT NULL
       OR NEW.digital_persona_last_error IS NOT NULL THEN
      v_changed := TRUE;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.digital_persona_source_platform IS DISTINCT FROM OLD.digital_persona_source_platform
       OR NEW.digital_persona_source_asset_id IS DISTINCT FROM OLD.digital_persona_source_asset_id
       OR NEW.digital_persona_playback_url IS DISTINCT FROM OLD.digital_persona_playback_url
       OR NEW.digital_persona_format IS DISTINCT FROM OLD.digital_persona_format
       OR NEW.digital_persona_status IS DISTINCT FROM OLD.digital_persona_status
       OR NEW.digital_persona_verified_at IS DISTINCT FROM OLD.digital_persona_verified_at
       OR NEW.digital_persona_last_error IS DISTINCT FROM OLD.digital_persona_last_error THEN
      v_changed := TRUE;
    END IF;
  END IF;

  IF v_changed THEN
    RAISE EXCEPTION 'digital_persona binding fields are managed by server only; use partner-video-verify edge function'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_digital_persona_binding ON public.managers;
CREATE TRIGGER trg_protect_digital_persona_binding
  BEFORE INSERT OR UPDATE ON public.managers
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_digital_persona_binding();

-- 5. 更新 get_public_manager_card RPC：移除旧字段，只暴露 3 个公开字段，非 active 时置空 URL 与 format
CREATE OR REPLACE FUNCTION public.get_public_manager_card(p_manager_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_manager managers%ROWTYPE;
  v_profile profiles%ROWTYPE;
  v_courses JSON;
  v_featured_products JSON;
  v_is_example BOOLEAN;
  v_public_playback_url TEXT := NULL;
  v_public_format TEXT := NULL;
  v_public_status TEXT := NULL;
BEGIN
  IF p_manager_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_manager FROM managers WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_profile FROM profiles WHERE id = p_manager_id;

  v_is_example := COALESCE(v_manager.is_example, false);

  -- 只有 active 才把 playback_url 和 format 暴露给公开访客；其它状态只吐 status
  v_public_status := v_manager.digital_persona_status;
  IF v_public_status = 'active' THEN
    v_public_playback_url := v_manager.digital_persona_playback_url;
    v_public_format := v_manager.digital_persona_format;
  END IF;

  SELECT json_agg(
    json_build_object(
      'id', c.id,
      'title', c.title,
      'cover_image_url', c.cover_image_url,
      'description', c.description,
      'duration_minutes', c.duration_minutes,
      'chapter_count', (
        SELECT COUNT(*)
        FROM manager_course_chapters mcc
        WHERE mcc.course_id = c.id AND mcc.is_active = true
      ),
      'sort_weight', c.sort_weight,
      'visibility', c.visibility
    )
    ORDER BY c.sort_weight DESC, c.created_at DESC
  ) INTO v_courses
  FROM manager_courses c
  WHERE c.manager_id = p_manager_id
    AND c.is_published = true
    AND c.review_status = 'approved';

  IF v_manager.featured_product_ids IS NOT NULL
     AND array_length(v_manager.featured_product_ids, 1) > 0 THEN
    SELECT json_agg(
      json_build_object(
        'id', p.id,
        'title', p.title,
        'cover_image_url', p.cover_image_url,
        'price_cents', sku.price_cents
      )
    ) INTO v_featured_products
    FROM products p
    LEFT JOIN product_skus sku
      ON sku.product_id = p.id
     AND sku.is_default = true
     AND sku.is_active = true
    WHERE p.id = ANY (v_manager.featured_product_ids)
      AND p.status = 'active';
  END IF;

  RETURN json_build_object(
    'manager_id', v_manager.id,
    'short_code', v_manager.short_code,
    'display_name', COALESCE(v_manager.partner_card_display_name, v_profile.nickname, '健康管理师'),
    'avatar_url', COALESCE(v_manager.digital_avatar_image_url, v_manager.partner_card_avatar_url, v_profile.avatar_url),
    'tagline', v_manager.tagline,
    'company_name', COALESCE(v_manager.company_name, v_manager.partner_card_company_name, v_manager.business_name),
    'intro_personal', v_manager.intro_personal,
    'intro_company', v_manager.intro_company,
    'credentials', v_manager.credentials,
    'digital_persona_playback_url', v_public_playback_url,
    'digital_persona_format', v_public_format,
    'digital_persona_status', v_public_status,
    'partner_card_public_url', v_manager.partner_card_public_url,
    'partner_card_synced_at', v_manager.partner_card_synced_at,
    'is_example', v_is_example,
    'public_contact_phone', v_manager.public_contact_phone,
    'featured_products', COALESCE(v_featured_products, '[]'::JSON),
    'courses', COALESCE(v_courses, '[]'::JSON)
  );
END;
$function$;