CREATE OR REPLACE FUNCTION public.get_public_course_sections(p_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
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
      c.id, c.title, c.cover_image_url, c.description, c.duration_minutes,
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

REVOKE ALL ON FUNCTION public.get_public_course_sections(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_course_sections(uuid) TO anon, authenticated;