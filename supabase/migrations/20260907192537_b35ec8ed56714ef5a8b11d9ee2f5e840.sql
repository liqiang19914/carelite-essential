-- feature 457: 企业课程公开/商户接口输出短码 + 商品详情按归属解析企业根

-- 5) 企业课程公开列表：course 增加 short_code
CREATE OR REPLACE FUNCTION public.get_public_enterprise_courses(p_manager_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_eid uuid;
  v_categories jsonb;
  v_courses jsonb;
BEGIN
  v_root := public.get_enterprise_root_manager_id(p_manager_id);
  IF v_root IS NULL OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN NULL;
  END IF;
  v_eid := public.get_profile_enterprise_id(v_root);

  SELECT COALESCE(jsonb_agg(to_jsonb(cat) ORDER BY cat.sort_weight DESC, cat.id), '[]'::jsonb)
    INTO v_categories
  FROM (
    SELECT id, name, sort_weight, cover_url
    FROM public.enterprise_course_categories
    WHERE enterprise_id = v_eid
  ) cat;

  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.sort_weight DESC, c.created_at DESC), '[]'::jsonb)
    INTO v_courses
  FROM (
    SELECT
      c.id, c.short_code, c.title, c.cover_image_url, c.description, c.duration_minutes,
      c.category_id, c.study_count, c.like_count, c.sort_weight, c.created_at,
      (SELECT COUNT(*) FROM public.enterprise_course_chapters mcc WHERE mcc.course_id = c.id) AS chapter_count
    FROM public.enterprise_courses c
    WHERE c.enterprise_id = v_eid AND c.is_published = true
  ) c;

  RETURN jsonb_build_object(
    'root_manager_id', v_root,
    'categories', v_categories,
    'courses', v_courses
  );
END;
$function$;

-- 6) 企业课程公开详情：返回 short_code（详情页分享/转发重建短码路径用）
CREATE OR REPLACE FUNCTION public.get_public_enterprise_course_detail(p_manager_id uuid, p_course_id uuid)
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
BEGIN
  v_root := public.get_enterprise_root_manager_id(p_manager_id);
  IF v_root IS NULL OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN NULL;
  END IF;
  v_eid := public.get_profile_enterprise_id(v_root);

  SELECT to_jsonb(c) INTO v_course
  FROM (
    SELECT id, short_code, title, cover_image_url, description, duration_minutes, category_id, study_count, like_count
    FROM public.enterprise_courses
    WHERE id = p_course_id AND enterprise_id = v_eid AND is_published = true
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
    WHERE course_id = p_course_id
  ) ch;

  IF v_uid IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.enterprise_course_likes
      WHERE course_id = p_course_id AND user_id = v_uid
    ) INTO v_my_liked;
  END IF;

  RETURN v_course || jsonb_build_object(
    'chapters', v_chapters,
    'my_liked', COALESCE(v_my_liked, false)
  );
END;
$function$;

-- 7) 商户侧企业课程列表（后台二维码/预览）：course 增加 short_code
CREATE OR REPLACE FUNCTION public.list_enterprise_courses()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_categories jsonb;
  v_courses jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', '未登录');
  END IF;
  IF NOT public.has_enterprise_permission('content', v_uid) THEN
    RETURN jsonb_build_object('error', '权限不足');
  END IF;
  v_eid := public.get_profile_enterprise_id(v_uid);

  SELECT COALESCE(jsonb_agg(to_jsonb(cat) ORDER BY cat.sort_weight DESC, cat.id), '[]'::jsonb)
    INTO v_categories
  FROM (
    SELECT id, name, sort_weight, cover_url
    FROM public.enterprise_course_categories
    WHERE enterprise_id = v_eid
  ) cat;

  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.sort_weight DESC, c.updated_at DESC), '[]'::jsonb)
    INTO v_courses
  FROM (
    SELECT
      c.id, c.short_code, c.category_id, c.title, c.cover_image_url, c.description,
      c.duration_minutes, c.is_published, c.sort_weight, c.study_count, c.like_count,
      c.created_at, c.updated_at,
      (SELECT COUNT(*) FROM public.enterprise_course_chapters mcc WHERE mcc.course_id = c.id) AS chapter_count,
      (SELECT COUNT(*) FROM public.health_manager_course_links hmcl WHERE hmcl.course_id = c.id) AS linked_manager_count
    FROM public.enterprise_courses c
    WHERE c.enterprise_id = v_eid
  ) c;

  RETURN jsonb_build_object(
    'categories', v_categories,
    'courses', v_courses
  );
END;
$function$;

-- 8) 商品详情：无店上下文时按商品归属解析企业根（分享链接去掉 ?shopRoot 参数后仍可打开，
--    且只要传入的店与商品归属不一致就返回空 —— 防跨店参数伪造）
CREATE OR REPLACE FUNCTION public.get_storefront_product_detail(p_product_id uuid, p_shop_root uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_product public.products;
  v_root    uuid;
  v_sku     jsonb;
BEGIN
  SELECT * INTO v_product
  FROM public.products
  WHERE id = p_product_id AND status = 'active';
  IF v_product.id IS NULL THEN
    RETURN NULL;
  END IF;

  -- 非空店铺参数先解析企业根，解析不出 = 无效店铺，直接空
  IF p_shop_root IS NOT NULL THEN
    v_root := public.get_enterprise_root_manager_id(p_shop_root);
    IF v_root IS NULL THEN
      RETURN NULL;
    END IF;
  END IF;

  -- 平台商品只在平台主店（无店上下文）可见
  IF v_product.source_type = 'platform' AND v_root IS NOT NULL THEN
    RETURN NULL;
  END IF;

  -- 商户商品：归属店可见；无店上下文（分享链接直接打开）按商品归属解析企业根，游客可见性沿用店级规则；
  -- 只要请求上下文与商品真实归属不一致就返回空，?shopRoot 参数不可伪造跨店读取
  IF v_product.source_type = 'manager' THEN
    IF v_product.owner_manager_id IS NULL THEN
      RETURN NULL;
    END IF;
    v_root := COALESCE(v_root, public.get_enterprise_root_manager_id(v_product.owner_manager_id));
    IF public.get_enterprise_root_manager_id(v_product.owner_manager_id) IS DISTINCT FROM v_root THEN
      RETURN NULL;
    END IF;
  END IF;

  SELECT jsonb_agg(to_jsonb(s)) INTO v_sku
  FROM public.product_skus s
  WHERE s.product_id = v_product.id
    AND s.is_default = true
    AND s.is_active = true;

  RETURN jsonb_build_object(
    'product', to_jsonb(v_product),
    'default_sku', COALESCE(v_sku -> 0, NULL)
  );
END;
$function$;