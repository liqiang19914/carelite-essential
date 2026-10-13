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

  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.sort_weight DESC, c.updated_at DESC), '[]'::jsonb)
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