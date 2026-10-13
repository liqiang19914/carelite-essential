-- 457：公开详情 RPC 的关联对象参数改为 text，先 6 位短码解析、再回退存量 UUID
-- 保持输出契约不变；短码全表唯一（partial 唯一索引），归属/可见性仍在原查询里强制。

DROP FUNCTION IF EXISTS public.get_public_content_item(p_manager_id uuid, p_content_id uuid);
CREATE OR REPLACE FUNCTION public.get_public_content_item(p_manager_id uuid, p_content_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_name text;
  v_item jsonb;
  v_pages jsonb := '[]'::jsonb;
  v_type text;
  v_like_count integer;
  v_view_count integer;
  v_base_view integer;
  v_my_liked boolean := false;
  v_uid uuid := auth.uid();
  v_resolved uuid;
BEGIN
  IF p_manager_id IS NULL OR p_content_id IS NULL OR btrim(p_content_id) = '' THEN
    RETURN NULL;
  END IF;

  v_root := public.get_enterprise_root_manager_id(p_manager_id);

  IF v_root IS NULL
     OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN NULL;
  END IF;

  -- 先短码后 UUID：新链接短码直查，存量 UUID 链接继续可用
  IF p_content_id ~ '^[0-9a-z]{6}$' THEN
    SELECT id INTO v_resolved
    FROM public.manager_content_items
    WHERE short_code = p_content_id;
  END IF;

  IF v_resolved IS NULL THEN
    BEGIN
      v_resolved := p_content_id::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_resolved := NULL;
    END;
  END IF;

  IF v_resolved IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT NULLIF(btrim(display_name), '') INTO v_name
  FROM public.manager_content_spaces
  WHERE root_manager_id = v_root;

  SELECT
    content_type,
    like_count,
    view_count,
    base_view_count,
    jsonb_build_object(
      'id', id,
      'short_code', short_code,
      'content_type', content_type,
      'title', title,
      'cover_url', cover_url,
      'article_doc', article_doc,
      'created_at', created_at,
      'updated_at', updated_at
    )
    INTO v_type, v_like_count, v_view_count, v_base_view, v_item
  FROM public.manager_content_items
  WHERE id = v_resolved
    AND root_manager_id = v_root
    AND is_published = true
    AND moderation_status = 'passed';

  IF v_item IS NULL THEN
    RETURN NULL;
  END IF;

  UPDATE public.manager_content_items
     SET view_count = view_count + 1
   WHERE id = v_resolved;

  v_view_count := COALESCE(v_view_count, 0) + 1 + COALESCE(v_base_view, 0);

  IF v_type = 'album' THEN
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id', id,
          'sort_order', sort_order,
          'image_url', image_url,
          'alt_text', alt_text
        ) ORDER BY sort_order
      ),
      '[]'::jsonb
    ) INTO v_pages
    FROM public.manager_content_album_pages
    WHERE content_id = v_resolved;
  END IF;

  IF v_uid IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.manager_content_likes
      WHERE content_id = v_resolved AND user_id = v_uid
    ) INTO v_my_liked;
  END IF;

  RETURN v_item || jsonb_build_object(
    'root_manager_id', v_root,
    'display_name', COALESCE(v_name, '健康学堂'),
    'pages', v_pages,
    'like_count', COALESCE(v_like_count, 0),
    'view_count', COALESCE(v_view_count, 0),
    'my_liked', COALESCE(v_my_liked, false)
  );
END;
$function$;
GRANT EXECUTE ON FUNCTION public.get_public_content_item(uuid, text) TO anon, authenticated;

DROP FUNCTION IF EXISTS public.get_public_enterprise_course_detail(p_manager_id uuid, p_course_id uuid);
CREATE OR REPLACE FUNCTION public.get_public_enterprise_course_detail(p_manager_id uuid, p_course_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_eid uuid;
  v_course jsonb;
  v_chapters jsonb;
  v_my_liked boolean := false;
  v_uid uuid := auth.uid();
  v_resolved uuid;
BEGIN
  IF p_manager_id IS NULL OR p_course_id IS NULL OR btrim(p_course_id) = '' THEN
    RETURN NULL;
  END IF;

  v_root := public.get_enterprise_root_manager_id(p_manager_id);
  IF v_root IS NULL OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN NULL;
  END IF;
  v_eid := public.get_profile_enterprise_id(v_root);

  IF p_course_id ~ '^[0-9a-z]{6}$' THEN
    SELECT id INTO v_resolved
    FROM public.enterprise_courses
    WHERE short_code = p_course_id;
  END IF;

  IF v_resolved IS NULL THEN
    BEGIN
      v_resolved := p_course_id::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_resolved := NULL;
    END;
  END IF;

  IF v_resolved IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT to_jsonb(c) INTO v_course
  FROM (
    SELECT id, short_code, title, cover_image_url, description, duration_minutes, category_id, study_count, like_count
    FROM public.enterprise_courses
    WHERE id = v_resolved AND enterprise_id = v_eid AND is_published = true
  ) c;

  IF v_course IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(
    jsonb_agg(to_jsonb(ch) ORDER BY ch.sort_order),
    '[]'::jsonb
  ) INTO v_chapters
  FROM (
    SELECT id, sort_order, title, intro, duration_seconds, video_url, video_source, cover_url, is_free_preview
    FROM public.enterprise_course_chapters
    WHERE course_id = v_resolved
  ) ch;

  IF v_uid IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.enterprise_course_likes
      WHERE course_id = v_resolved AND user_id = v_uid
    ) INTO v_my_liked;
  END IF;

  RETURN v_course || jsonb_build_object(
    'chapters', v_chapters,
    'my_liked', COALESCE(v_my_liked, false)
  );
END;
$function$;
GRANT EXECUTE ON FUNCTION public.get_public_enterprise_course_detail(uuid, text) TO anon, authenticated;

DROP FUNCTION IF EXISTS public.get_public_manager_course(p_manager_id uuid, p_course_id uuid);
CREATE OR REPLACE FUNCTION public.get_public_manager_course(p_manager_id uuid, p_course_id text)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_course manager_courses%ROWTYPE;
  v_chapters JSON;
  v_is_bound BOOLEAN := false;
  v_uid UUID;
  v_like_count INTEGER := 0;
  v_study_count INTEGER := 0;
  v_my_liked BOOLEAN := false;
  v_my_studied BOOLEAN := false;
  v_products JSON;
  v_resolved UUID;
BEGIN
  IF p_manager_id IS NULL OR p_course_id IS NULL OR btrim(p_course_id) = '' THEN
    RETURN NULL;
  END IF;

  v_uid := auth.uid();

  IF p_course_id ~ '^[0-9a-z]{6}$' THEN
    SELECT id INTO v_resolved
    FROM manager_courses
    WHERE short_code = p_course_id;
  END IF;

  IF v_resolved IS NULL THEN
    BEGIN
      v_resolved := p_course_id::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_resolved := NULL;
    END;
  END IF;

  IF v_resolved IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_course
  FROM manager_courses
  WHERE id = v_resolved
    AND manager_id = p_manager_id
    AND is_published = true
    AND review_status = 'approved';

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_course.visibility = 'clients_only' THEN
    IF v_uid IS NULL THEN
      RETURN json_build_object(
        'gated', true,
        'reason', 'unauthenticated',
        'manager_id', v_course.manager_id
      );
    END IF;

    SELECT EXISTS (
      SELECT 1 FROM client_relations
      WHERE client_id = v_uid
        AND manager_id = p_manager_id
        AND status = 'active'
    ) INTO v_is_bound;

    IF NOT v_is_bound AND NOT public.is_admin(v_uid) THEN
      RETURN json_build_object(
        'gated', true,
        'reason', 'not_bound',
        'manager_id', v_course.manager_id
      );
    END IF;
  END IF;

  SELECT json_agg(
    json_build_object(
      'id', mcc.id,
      'sort_order', mcc.sort_order,
      'title', mcc.title,
      'intro', mcc.intro,
      'duration_seconds', mcc.duration_seconds,
      'video_url', mcc.video_url,
      'video_source', mcc.video_source,
      'cover_url', mcc.cover_url,
      'is_free_preview', mcc.is_free_preview,
      'is_active', mcc.is_active
    )
    ORDER BY mcc.sort_order ASC, mcc.created_at ASC
  ) INTO v_chapters
  FROM manager_course_chapters mcc
  WHERE mcc.course_id = v_course.id
    AND mcc.is_active = true;

  v_like_count := COALESCE(v_course.like_count, 0);
  v_study_count := COALESCE(v_course.study_count, 0);
  IF v_uid IS NOT NULL THEN
    SELECT EXISTS (SELECT 1 FROM course_likes WHERE course_id = v_resolved AND user_id = v_uid) INTO v_my_liked;
    SELECT EXISTS (SELECT 1 FROM course_studies WHERE course_id = v_resolved AND user_id = v_uid) INTO v_my_studied;
  END IF;

  IF v_course.related_product_ids IS NOT NULL AND array_length(v_course.related_product_ids, 1) > 0 THEN
    SELECT json_agg(
      json_build_object(
        'id', p.id,
        'title', p.title,
        'cover_image_url', p.cover_image_url,
        'price_cents', sku.price_cents
      )
    ) INTO v_products
    FROM products p
    LEFT JOIN product_skus sku
      ON sku.product_id = p.id AND sku.is_default = true AND sku.is_active = true
    WHERE p.id = ANY (v_course.related_product_ids)
      AND p.status = 'active';
  END IF;

  RETURN json_build_object(
    'id', v_course.id,
    'short_code', v_course.short_code,
    'manager_id', v_course.manager_id,
    'title', v_course.title,
    'cover_image_url', v_course.cover_image_url,
    'description', v_course.description,
    'duration_minutes', v_course.duration_minutes,
    'visibility', v_course.visibility,
    'like_count', v_like_count,
    'study_count', v_study_count,
    'my_liked', v_my_liked,
    'my_studied', v_my_studied,
    'related_products', COALESCE(v_products, '[]'::JSON),
    'chapters', COALESCE(v_chapters, '[]'::JSON),
    'created_at', v_course.created_at
  );
END;
$function$;
GRANT EXECUTE ON FUNCTION public.get_public_manager_course(uuid, text) TO anon, authenticated;