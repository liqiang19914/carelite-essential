-- feature 457: 公开/商户读取接口输出短码，前端生成端据此拼 6 位短码链接

-- 1) 公开内容列表模块：item 增加 short_code
CREATE OR REPLACE FUNCTION public.get_public_content_module(p_manager_id uuid, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0, p_content_type text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_name text;
  v_total integer;
  v_items jsonb;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  v_offset integer := LEAST(GREATEST(COALESCE(p_offset, 0), 0), 10000);
  v_type_filter text := CASE WHEN p_content_type IN ('article', 'album') THEN p_content_type ELSE NULL END;
BEGIN
  v_root := public.get_enterprise_root_manager_id(p_manager_id);

  IF v_root IS NULL
     OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN NULL;
  END IF;

  SELECT NULLIF(btrim(display_name), '') INTO v_name
  FROM public.manager_content_spaces
  WHERE root_manager_id = v_root;

  SELECT COUNT(*) INTO v_total
  FROM public.manager_content_items
  WHERE root_manager_id = v_root
    AND is_published = true
    AND moderation_status = 'passed'
    AND (v_type_filter IS NULL OR content_type = v_type_filter);

  SELECT COALESCE(jsonb_agg(to_jsonb(item)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT
      i.id,
      i.short_code,
      i.content_type,
      i.title,
      i.cover_url,
      i.sort_weight,
      i.created_at,
      i.updated_at,
      i.like_count,
      COALESCE(i.is_pinned, false) AS is_pinned,
      COALESCE(i.view_count, 0) + COALESCE(i.base_view_count, 0) AS view_count,
      CASE
        WHEN i.content_type = 'album' THEN (
          SELECT COUNT(*)
          FROM public.manager_content_album_pages p
          WHERE p.content_id = i.id
        )
        ELSE 0
      END AS page_count
    FROM public.manager_content_items i
    WHERE i.root_manager_id = v_root
      AND i.is_published = true
      AND i.moderation_status = 'passed'
      AND (v_type_filter IS NULL OR i.content_type = v_type_filter)
    ORDER BY
      COALESCE(i.is_pinned, false) DESC,
      COALESCE(i.pinned_rank, 0) DESC,
      i.sort_weight DESC,
      i.created_at DESC,
      i.id
    LIMIT v_limit OFFSET v_offset
  ) item;

  RETURN jsonb_build_object(
    'root_manager_id', v_root,
    'display_name', COALESCE(v_name, '健康学堂'),
    'total', v_total,
    'items', v_items
  );
END;
$function$;

-- 2) 公开内容详情：返回 short_code（详情页分享/转发重建短码路径用）
CREATE OR REPLACE FUNCTION public.get_public_content_item(p_manager_id uuid, p_content_id uuid)
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
BEGIN
  v_root := public.get_enterprise_root_manager_id(p_manager_id);

  IF v_root IS NULL
     OR NOT public.is_public_enterprise_content_root(v_root) THEN
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
  WHERE id = p_content_id
    AND root_manager_id = v_root
    AND is_published = true
    AND moderation_status = 'passed';

  IF v_item IS NULL THEN
    RETURN NULL;
  END IF;

  UPDATE public.manager_content_items
     SET view_count = view_count + 1
   WHERE id = p_content_id;

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
    WHERE content_id = p_content_id;
  END IF;

  IF v_uid IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.manager_content_likes
      WHERE content_id = p_content_id AND user_id = v_uid
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

-- 3) 健管师课程公开列表（get_public_course_sections）：course 增加 short_code
CREATE OR REPLACE FUNCTION public.get_public_course_sections(p_manager_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_categories jsonb;
  v_courses jsonb;
BEGIN
  v_root := public.get_enterprise_root_manager_id(p_manager_id);
  IF v_root IS NULL OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(cat)), '[]'::jsonb) INTO v_categories
  FROM (
    SELECT cat.id, cat.name, cat.sort_weight, cat.cover_url
    FROM public.manager_course_categories cat
    WHERE cat.root_manager_id = v_root
    ORDER BY cat.sort_weight DESC, cat.id
  ) cat;

  SELECT COALESCE(jsonb_agg(to_jsonb(c)), '[]'::jsonb) INTO v_courses
  FROM (
    SELECT
      c.id, c.short_code, c.title, c.cover_image_url, c.description, c.duration_minutes,
      c.category_id, c.study_count, c.like_count, c.visibility, c.sort_weight,
      (
        SELECT COUNT(*) FROM public.manager_course_chapters mcc
        WHERE mcc.course_id = c.id AND mcc.is_active = true
      ) AS chapter_count
    FROM public.manager_courses c
    WHERE c.is_published = true
      AND c.review_status = 'approved'
      AND (
        c.manager_id = v_root
        OR c.manager_id IN (
          SELECT p2.id FROM public.profiles p2
          WHERE p2.parent_manager_id = v_root AND p2.role = 'manager'
        )
      )
    ORDER BY c.sort_weight DESC, c.created_at DESC
  ) c;

  RETURN jsonb_build_object(
    'root_manager_id', v_root,
    'categories', v_categories,
    'courses', v_courses
  );
END;
$function$;

-- 4) 健管师课程详情（公开名片 /m/:id/course/:courseId）：返回 short_code
CREATE OR REPLACE FUNCTION public.get_public_manager_course(p_manager_id uuid, p_course_id uuid)
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
BEGIN
  IF p_manager_id IS NULL OR p_course_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_uid := auth.uid();

  SELECT * INTO v_course
  FROM manager_courses
  WHERE id = p_course_id
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
    SELECT EXISTS (SELECT 1 FROM course_likes WHERE course_id = p_course_id AND user_id = v_uid) INTO v_my_liked;
    SELECT EXISTS (SELECT 1 FROM course_studies WHERE course_id = p_course_id AND user_id = v_uid) INTO v_my_studied;
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