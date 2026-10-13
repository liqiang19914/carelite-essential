-- Feature 133 第三部分：企业级课程管理 RPC（栏目/课程/章节/关联）

CREATE OR REPLACE FUNCTION public.save_enterprise_course_category(
  p_id uuid,
  p_name text,
  p_sort_weight integer,
  p_cover_url text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_result jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', '未登录');
  END IF;
  IF NOT public.has_enterprise_permission('content', v_uid) THEN
    RETURN jsonb_build_object('error', '权限不足');
  END IF;
  v_eid := public.get_profile_enterprise_id(v_uid);

  IF p_id IS NULL THEN
    INSERT INTO public.enterprise_course_categories (enterprise_id, name, sort_weight, cover_url)
    VALUES (v_eid, COALESCE(p_name, ''), COALESCE(p_sort_weight, 0), p_cover_url)
    RETURNING to_jsonb(enterprise_course_categories.*) INTO v_result;
  ELSE
    UPDATE public.enterprise_course_categories
       SET name = COALESCE(p_name, name),
           sort_weight = COALESCE(p_sort_weight, sort_weight),
           cover_url = COALESCE(p_cover_url, cover_url),
           updated_at = NOW()
     WHERE id = p_id AND enterprise_id = v_eid
    RETURNING to_jsonb(enterprise_course_categories.*) INTO v_result;

    IF v_result IS NULL THEN
      RETURN jsonb_build_object('error', '栏目不存在或无权操作');
    END IF;
  END IF;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.save_enterprise_course_category(uuid, text, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_enterprise_course_category(uuid, text, integer, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.delete_enterprise_course_category(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_eid uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', '未登录');
  END IF;
  IF NOT public.has_enterprise_permission('content', v_uid) THEN
    RETURN jsonb_build_object('error', '权限不足');
  END IF;
  v_eid := public.get_profile_enterprise_id(v_uid);

  DELETE FROM public.enterprise_course_categories
   WHERE id = p_id AND enterprise_id = v_eid;

  RETURN jsonb_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_enterprise_course_category(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_enterprise_course_category(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.save_enterprise_course(
  p_id uuid,
  p_category_id uuid,
  p_title text,
  p_cover_image_url text,
  p_description text,
  p_duration_minutes integer,
  p_is_published boolean,
  p_sort_weight integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_result jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', '未登录');
  END IF;
  IF NOT public.has_enterprise_permission('content', v_uid) THEN
    RETURN jsonb_build_object('error', '权限不足');
  END IF;
  v_eid := public.get_profile_enterprise_id(v_uid);

  IF p_category_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.enterprise_course_categories WHERE id = p_category_id AND enterprise_id = v_eid
  ) THEN
    RETURN jsonb_build_object('error', '栏目不存在或无权操作');
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.enterprise_courses
      (enterprise_id, category_id, title, cover_image_url, description, duration_minutes, is_published, sort_weight)
    VALUES
      (v_eid, p_category_id, COALESCE(p_title, ''), p_cover_image_url, p_description, p_duration_minutes, COALESCE(p_is_published, false), COALESCE(p_sort_weight, 0))
    RETURNING to_jsonb(enterprise_courses.*) INTO v_result;
  ELSE
    UPDATE public.enterprise_courses
       SET category_id = p_category_id,
           title = COALESCE(p_title, title),
           cover_image_url = COALESCE(p_cover_image_url, cover_image_url),
           description = COALESCE(p_description, description),
           duration_minutes = COALESCE(p_duration_minutes, duration_minutes),
           is_published = COALESCE(p_is_published, is_published),
           sort_weight = COALESCE(p_sort_weight, sort_weight),
           updated_at = NOW()
     WHERE id = p_id AND enterprise_id = v_eid
    RETURNING to_jsonb(enterprise_courses.*) INTO v_result;

    IF v_result IS NULL THEN
      RETURN jsonb_build_object('error', '课程不存在或无权操作');
    END IF;
  END IF;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.save_enterprise_course(uuid, uuid, text, text, text, integer, boolean, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_enterprise_course(uuid, uuid, text, text, text, integer, boolean, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.delete_enterprise_course(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_eid uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', '未登录');
  END IF;
  IF NOT public.has_enterprise_permission('content', v_uid) THEN
    RETURN jsonb_build_object('error', '权限不足');
  END IF;
  v_eid := public.get_profile_enterprise_id(v_uid);

  DELETE FROM public.enterprise_courses
   WHERE id = p_id AND enterprise_id = v_eid;

  RETURN jsonb_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_enterprise_course(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_enterprise_course(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.save_enterprise_course_chapters(
  p_course_id uuid,
  p_chapters jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_count integer;
  ch jsonb;
  v_order integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', '未登录');
  END IF;
  IF NOT public.has_enterprise_permission('content', v_uid) THEN
    RETURN jsonb_build_object('error', '权限不足');
  END IF;
  v_eid := public.get_profile_enterprise_id(v_uid);

  IF NOT EXISTS (
    SELECT 1 FROM public.enterprise_courses WHERE id = p_course_id AND enterprise_id = v_eid
  ) THEN
    RETURN jsonb_build_object('error', '课程不存在或无权操作');
  END IF;

  DELETE FROM public.enterprise_course_chapters WHERE course_id = p_course_id;

  IF p_chapters IS NOT NULL AND jsonb_typeof(p_chapters) = 'array' THEN
    FOR ch IN SELECT * FROM jsonb_array_elements(p_chapters)
    LOOP
      v_order := v_order + 1;
      INSERT INTO public.enterprise_course_chapters
        (course_id, sort_order, title, intro, duration_seconds, video_url, video_storage_key, video_source, cover_url, is_free_preview)
      VALUES
        (p_course_id, v_order,
         COALESCE((ch->>'title'), ''),
         NULLIF(ch->>'intro', ''),
         NULLIF(ch->>'duration_seconds', '')::integer,
         NULLIF(ch->>'video_url', ''),
         NULLIF(ch->>'video_storage_key', ''),
         COALESCE(ch->>'video_source', 'upload'),
         NULLIF(ch->>'cover_url', ''),
         COALESCE((ch->>'is_free_preview')::boolean, false));
    END LOOP;
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.enterprise_course_chapters WHERE course_id = p_course_id;

  RETURN jsonb_build_object('chapter_count', v_count);
END;
$function$;

REVOKE ALL ON FUNCTION public.save_enterprise_course_chapters(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_enterprise_course_chapters(uuid, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_enterprise_course_links(
  p_course_id uuid,
  p_manager_ids uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_bad integer;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', '未登录');
  END IF;

  v_eid := public.get_profile_enterprise_id(v_uid);

  IF NOT EXISTS (
    SELECT 1 FROM public.enterprise_courses WHERE id = p_course_id AND enterprise_id = v_eid
  ) THEN
    RETURN jsonb_build_object('error', '课程不存在或无权操作');
  END IF;

  -- 关联动作：课程所属企业的 content 权限成员，或健管师本人（关联到自己）
  IF NOT public.has_enterprise_permission('content', v_uid)
     AND NOT (
       p_manager_ids IS NOT NULL
       AND array_length(p_manager_ids, 1) = 1
       AND p_manager_ids[1] = v_uid
       AND EXISTS (SELECT 1 FROM public.managers m WHERE m.id = v_uid AND m.enterprise_id = v_eid)
     ) THEN
    RETURN jsonb_build_object('error', '权限不足');
  END IF;

  IF p_manager_ids IS NOT NULL AND array_length(p_manager_ids, 1) > 0 THEN
    SELECT COUNT(*) INTO v_bad
    FROM unnest(p_manager_ids) AS mid
    LEFT JOIN public.managers m ON m.id = mid
    WHERE m.enterprise_id IS DISTINCT FROM v_eid;

    IF v_bad > 0 THEN
      RETURN jsonb_build_object('error', '存在不属于本企业的健管师');
    END IF;
  END IF;

  DELETE FROM public.health_manager_course_links WHERE course_id = p_course_id;

  IF p_manager_ids IS NOT NULL AND array_length(p_manager_ids, 1) > 0 THEN
    INSERT INTO public.health_manager_course_links (manager_id, course_id)
    SELECT mid, p_course_id FROM unnest(p_manager_ids) AS mid
    ON CONFLICT (manager_id, course_id) DO NOTHING;
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.set_enterprise_course_links(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_enterprise_course_links(uuid, uuid[]) TO authenticated;