-- Feature 133 第四部分：企业级课程公开读取 + 互动 RPC

-- 商户端：当前企业的课程 + 栏目（含统计）
CREATE OR REPLACE FUNCTION public.list_enterprise_courses()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
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

  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.is_pinned DESC, c.pinned_rank DESC, c.sort_weight DESC, c.updated_at DESC), '[]'::jsonb)
    INTO v_courses
  FROM (
    SELECT
      c.id, c.category_id, c.title, c.cover_image_url, c.description,
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

REVOKE ALL ON FUNCTION public.list_enterprise_courses() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_enterprise_courses() TO authenticated;

-- 客户侧：企业已发布课程 + 栏目（公开）
CREATE OR REPLACE FUNCTION public.get_public_enterprise_courses(p_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
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
      c.id, c.title, c.cover_image_url, c.description, c.duration_minutes,
      c.category_id, c.study_count, c.like_count, c.sort_weight,
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

REVOKE ALL ON FUNCTION public.get_public_enterprise_courses(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_enterprise_courses(uuid) TO anon, authenticated;

-- 客户侧：企业课程详情 + 章节 + 互动状态（公开）
CREATE OR REPLACE FUNCTION public.get_public_enterprise_course_detail(p_manager_id uuid, p_course_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
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
    SELECT id, title, cover_image_url, description, duration_minutes, category_id, study_count, like_count
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

REVOKE ALL ON FUNCTION public.get_public_enterprise_course_detail(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_enterprise_course_detail(uuid, uuid) TO anon, authenticated;

-- 客户侧：企业课程点赞切换
CREATE OR REPLACE FUNCTION public.toggle_enterprise_course_like(p_course_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_liked boolean := false;
  v_like_count integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再点赞' USING ERRCODE = '28000';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.enterprise_courses WHERE id = p_course_id) THEN
    RAISE EXCEPTION '课程不存在' USING ERRCODE = 'P0002';
  END IF;

  IF EXISTS (SELECT 1 FROM public.enterprise_course_likes WHERE course_id = p_course_id AND user_id = v_uid) THEN
    DELETE FROM public.enterprise_course_likes WHERE course_id = p_course_id AND user_id = v_uid;
    UPDATE public.enterprise_courses SET like_count = GREATEST(like_count - 1, 0) WHERE id = p_course_id;
    v_liked := false;
  ELSE
    INSERT INTO public.enterprise_course_likes (course_id, user_id) VALUES (p_course_id, v_uid);
    UPDATE public.enterprise_courses SET like_count = like_count + 1 WHERE id = p_course_id;
    v_liked := true;
  END IF;

  SELECT like_count INTO v_like_count FROM public.enterprise_courses WHERE id = p_course_id;
  RETURN jsonb_build_object('liked', v_liked, 'like_count', COALESCE(v_like_count, 0));
END;
$function$;

REVOKE ALL ON FUNCTION public.toggle_enterprise_course_like(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.toggle_enterprise_course_like(uuid) TO authenticated;

-- 客户侧：企业课程学习记录（去重）
CREATE OR REPLACE FUNCTION public.record_enterprise_course_study(p_course_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_recorded boolean := false;
  v_study_count integer;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('recorded', false, 'study_count', 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.enterprise_courses WHERE id = p_course_id) THEN
    RETURN jsonb_build_object('recorded', false, 'study_count', 0);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.enterprise_course_studies WHERE course_id = p_course_id AND user_id = v_uid) THEN
    INSERT INTO public.enterprise_course_studies (course_id, user_id) VALUES (p_course_id, v_uid);
    UPDATE public.enterprise_courses SET study_count = study_count + 1 WHERE id = p_course_id;
    v_recorded := true;
  END IF;

  SELECT study_count INTO v_study_count FROM public.enterprise_courses WHERE id = p_course_id;
  RETURN jsonb_build_object('recorded', v_recorded, 'study_count', COALESCE(v_study_count, 0));
END;
$function$;

REVOKE ALL ON FUNCTION public.record_enterprise_course_study(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_enterprise_course_study(uuid) TO authenticated;