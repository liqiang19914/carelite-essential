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