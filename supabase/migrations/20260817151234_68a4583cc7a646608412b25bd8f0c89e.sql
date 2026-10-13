CREATE OR REPLACE FUNCTION public.get_enterprise_course_detail(p_course_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_course jsonb;
  v_chapters jsonb;
  v_links jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', '未登录');
  END IF;
  IF NOT public.has_enterprise_permission('content', v_uid) THEN
    RETURN jsonb_build_object('error', '权限不足');
  END IF;
  v_eid := public.get_profile_enterprise_id(v_uid);

  SELECT to_jsonb(c) INTO v_course
  FROM (
    SELECT id, category_id, title, cover_image_url, description, duration_minutes, is_published, sort_weight
    FROM public.enterprise_courses
    WHERE id = p_course_id AND enterprise_id = v_eid
  ) c;

  IF v_course IS NULL THEN
    RETURN jsonb_build_object('error', '课程不存在或无权操作');
  END IF;

  SELECT COALESCE(
    jsonb_agg(to_jsonb(ch) ORDER BY ch.sort_order),
    '[]'::jsonb
  ) INTO v_chapters
  FROM (
    SELECT id, sort_order, title, intro, duration_seconds, video_url, video_storage_key, video_source, cover_url, is_free_preview
    FROM public.enterprise_course_chapters
    WHERE course_id = p_course_id
  ) ch;

  SELECT COALESCE(
    jsonb_agg(manager_id ORDER BY created_at),
    '[]'::jsonb
  ) INTO v_links
  FROM public.health_manager_course_links
  WHERE course_id = p_course_id;

  RETURN v_course || jsonb_build_object(
    'chapters', v_chapters,
    'linked_manager_ids', v_links
  );
END;
$function$;