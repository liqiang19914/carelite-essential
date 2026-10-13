-- 280: 智能体管理修复与公开展示统一
-- 1) 课程代管理权限判定：本人 / 平台管理员 / 同企业且有「编辑他人的智能体」权限 / 直属上级
CREATE OR REPLACE FUNCTION public.can_manage_manager_courses(p_manager_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR p_manager_id IS NULL THEN
    RETURN FALSE;
  END IF;
  IF public.is_admin(v_uid) THEN
    RETURN TRUE;
  END IF;
  IF p_manager_id = v_uid THEN
    RETURN TRUE;
  END IF;
  IF public.has_enterprise_permission('agent_edit', v_uid)
     AND public.get_profile_enterprise_id(p_manager_id) IS NOT NULL
     AND public.get_profile_enterprise_id(p_manager_id) = public.get_profile_enterprise_id(v_uid) THEN
    RETURN TRUE;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = p_manager_id AND parent_manager_id = v_uid
  ) THEN
    RETURN TRUE;
  END IF;
  RETURN FALSE;
END;
$function$;

REVOKE ALL ON FUNCTION public.can_manage_manager_courses(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_manage_manager_courses(uuid) TO authenticated;

-- 2) 课程 / 章节 RLS：owner、admin 之外，代管理权限者也能读写目标员工课程
DROP POLICY IF EXISTS "manager_courses_owner_all" ON manager_courses;
CREATE POLICY "manager_courses_owner_all"
  ON manager_courses FOR ALL
  USING (manager_id = auth.uid() OR public.can_manage_manager_courses(manager_id))
  WITH CHECK (manager_id = auth.uid() OR public.can_manage_manager_courses(manager_id));

DROP POLICY IF EXISTS "mcc_owner_all" ON manager_course_chapters;
CREATE POLICY "mcc_owner_all"
  ON manager_course_chapters FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM manager_courses c
      WHERE c.id = manager_course_chapters.course_id
        AND (c.manager_id = auth.uid() OR public.can_manage_manager_courses(c.manager_id))
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM manager_courses c
      WHERE c.id = manager_course_chapters.course_id
        AND (c.manager_id = auth.uid() OR public.can_manage_manager_courses(c.manager_id))
    )
  );

-- 3) 章节读取 RPC：代管理权限可读目标员工课程章节
CREATE OR REPLACE FUNCTION public.list_my_course_chapters(p_course_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $function$
DECLARE
  v_uid       UUID;
  v_owner_id  UUID;
  v_chapters  JSON;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  SELECT manager_id INTO v_owner_id FROM manager_courses WHERE id = p_course_id;
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION '课程不存在' USING ERRCODE = 'P0002';
  END IF;

  IF v_owner_id <> v_uid AND NOT public.can_manage_manager_courses(v_owner_id) THEN
    RAISE EXCEPTION '无权访问' USING ERRCODE = '42501';
  END IF;

  SELECT json_agg(
    json_build_object(
      'id', mcc.id,
      'sort_order', mcc.sort_order,
      'title', mcc.title,
      'intro', mcc.intro,
      'duration_seconds', mcc.duration_seconds,
      'video_url', mcc.video_url,
      'video_storage_key', mcc.video_storage_key,
      'video_source', mcc.video_source,
      'cover_url', mcc.cover_url,
      'is_free_preview', mcc.is_free_preview,
      'is_active', mcc.is_active,
      'created_at', mcc.created_at,
      'updated_at', mcc.updated_at
    )
    ORDER BY mcc.sort_order ASC, mcc.created_at ASC
  ) INTO v_chapters
  FROM manager_course_chapters mcc
  WHERE mcc.course_id = p_course_id;

  RETURN COALESCE(v_chapters, '[]'::JSON);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_my_course_chapters(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_course_chapters(uuid) TO authenticated;

-- 4) 提交审核 RPC：代管理权限可替目标员工提交
CREATE OR REPLACE FUNCTION public.submit_course_for_review(p_course_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uid       UUID;
  v_course    manager_courses%ROWTYPE;
  v_chap_cnt  INTEGER;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_course FROM manager_courses WHERE id = p_course_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '课程不存在' USING ERRCODE = 'P0002';
  END IF;

  IF v_course.manager_id <> v_uid AND NOT public.can_manage_manager_courses(v_course.manager_id) THEN
    RAISE EXCEPTION '只能提交自己的课程' USING ERRCODE = '42501';
  END IF;

  IF v_course.review_status = 'pending_review' THEN
    RAISE EXCEPTION '已在审核队列中' USING ERRCODE = '22023';
  END IF;

  IF v_course.review_status = 'approved' THEN
    RAISE EXCEPTION '课程已通过审核，无需重复提交' USING ERRCODE = '22023';
  END IF;

  SELECT COUNT(*) INTO v_chap_cnt
    FROM manager_course_chapters mcc
   WHERE mcc.course_id = p_course_id AND mcc.is_active = true;

  IF v_chap_cnt = 0 THEN
    RAISE EXCEPTION '请至少添加一个有效章节后再提交' USING ERRCODE = '22023';
  END IF;

  UPDATE manager_courses
     SET review_status = 'pending_review',
         submitted_at  = NOW(),
         review_note   = NULL
   WHERE id = p_course_id;

  RETURN json_build_object(
    'success', true,
    'course_id', p_course_id,
    'review_status', 'pending_review',
    'submitted_at', NOW()
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.submit_course_for_review(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_course_for_review(uuid) TO authenticated;

-- 5) 公开列表重写：企业根 + 全部在职员工（不再只限 health_manager 子角色），推荐优先排序
CREATE OR REPLACE FUNCTION public.list_public_enterprise_managers(p_manager_id uuid DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_root uuid;
  v_ent uuid;
  v_result json;
BEGIN
  IF p_manager_id IS NULL THEN
    SELECT value::uuid INTO v_root
      FROM public.system_settings
     WHERE key = 'platform_manager_root_id';
  ELSE
    SELECT p.id INTO v_root FROM public.profiles p WHERE p.id = p_manager_id;
    IF v_root IS NULL THEN
      RETURN '[]'::json;
    END IF;
  END IF;

  SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = v_root;
  IF v_ent IS NULL THEN
    RETURN '[]'::json;
  END IF;

  SELECT COALESCE(json_agg(x.row ORDER BY x.is_recommended DESC, x.recommend_rank ASC NULLS LAST, x.created_at ASC), '[]'::json)
  INTO v_result
  FROM (
    SELECT
      json_build_object(
        'manager_id', m.id,
        'short_code', m.short_code,
        'display_name', COALESCE(NULLIF(m.partner_card_display_name, ''), ep.nickname, '健康管理师'),
        'avatar_url', COALESCE(NULLIF(m.digital_avatar_image_url, ''), NULLIF(m.partner_card_avatar_url, ''), NULLIF(ep.avatar_url, '')),
        'tagline', NULLIF(m.tagline, ''),
        'intro_personal', NULLIF(m.intro_personal, ''),
        'company_name', NULLIF(COALESCE(m.company_name, m.partner_card_company_name, m.business_name), ''),
        'is_recommended', COALESCE(m.is_recommended, false),
        'credentials', COALESCE(m.credentials, ARRAY[]::text[]),
        'ai_enabled', COALESCE(m.public_qa_enabled, false),
        'consultation_count', (
          SELECT COUNT(DISTINCT q.visitor_token)
          FROM public.manager_public_qa_sessions q
          WHERE q.manager_id = m.id
        )
      ) AS row,
      COALESCE(m.is_recommended, false) AS is_recommended,
      m.recommend_rank,
      ep.created_at
    FROM public.profiles ep
    JOIN public.managers m ON m.id = ep.id
    WHERE ep.enterprise_id = v_ent
      AND ep.role = 'manager'
      AND ep.is_disabled = false
      AND COALESCE(m.is_example, false) = false
  ) x;

  RETURN v_result;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.list_public_enterprise_managers(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_public_enterprise_managers(uuid) TO anon, authenticated;