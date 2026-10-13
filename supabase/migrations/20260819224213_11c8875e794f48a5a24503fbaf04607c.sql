-- 全站逻辑隔离加固（Feature 198 · 第二批）
-- 1. 问卷分享链接改为 RPC 按码取卷：关掉「任何人可列出全部生效问卷」的枚举口
-- 2. 问卷三张表补平台管理员可读策略（原来管理员靠公共策略只能看到生效问卷）
-- 3. 公开名片的关联商品校验归属：只能挂本企业商品或平台自营，别家私域商品不再外露

-- ── 1. 问卷按分享码取卷（游客可填） ────────────────────────────
CREATE OR REPLACE FUNCTION public.get_public_survey_by_share_code(p_share_code text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_survey    public.surveys;
  v_questions jsonb;
BEGIN
  IF p_share_code IS NULL OR btrim(p_share_code) = '' THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_survey FROM public.surveys WHERE share_code = btrim(p_share_code);
  IF v_survey.id IS NULL THEN
    RETURN NULL;
  END IF;

  -- 已结束/草稿：回问卷本体但不回题目，填写页据 status 显示「已结束」
  IF v_survey.status <> 'active' THEN
    RETURN jsonb_build_object('survey', to_jsonb(v_survey), 'questions', '[]'::jsonb);
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.display_order), '[]'::jsonb)
    INTO v_questions
  FROM public.survey_questions q
  WHERE q.survey_id = v_survey.id;

  RETURN jsonb_build_object('survey', to_jsonb(v_survey), 'questions', v_questions);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_survey_by_share_code(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_survey_by_share_code(text) TO anon, authenticated;

-- 关掉公开枚举：此前任何人可列出全部「生效且有分享码」的问卷
DROP POLICY IF EXISTS "Anyone can view active surveys by share code" ON public.surveys;

-- ── 2. 平台管理员可读问卷三表（平台巡查用，原来只能靠公共策略看到生效问卷） ──
DROP POLICY IF EXISTS "Admins can view all surveys" ON public.surveys;
CREATE POLICY "Admins can view all surveys" ON public.surveys
  FOR SELECT USING (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Admins can view all survey questions" ON public.survey_questions;
CREATE POLICY "Admins can view all survey questions" ON public.survey_questions
  FOR SELECT USING (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Admins can view all survey responses" ON public.survey_responses;
CREATE POLICY "Admins can view all survey responses" ON public.survey_responses
  FOR SELECT USING (public.is_admin(auth.uid()));

-- ── 3. 公开名片关联商品校验归属 ────────────────────────────────
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
      AND p.status = 'active'
      -- 按店隔离：名片上只能挂平台自营（本来公开）或本企业的商品，别家私域商品不外露
      AND (
        p.source_type = 'platform'
        OR public.get_enterprise_root_manager_id(p.owner_manager_id) = public.get_enterprise_root_manager_id(p_manager_id)
      );
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