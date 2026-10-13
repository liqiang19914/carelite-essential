-- 276: 名片主推产品透传 store_only，装修引用列表才能显示【门店】标签
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
        'price_cents', sku.price_cents,
        'store_only', COALESCE(p.store_only, false)
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