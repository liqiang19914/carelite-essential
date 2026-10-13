-- ============================================================================
-- 问卷模块 RPC：save_survey_questions / assign_survey_to_clients /
-- mark_notification_read / mark_all_notifications_read
-- 以及历史 response_count 校准
-- ============================================================================

-- ---------- 1) save_survey_questions ----------
CREATE OR REPLACE FUNCTION public.save_survey_questions(
  p_survey_id uuid,
  p_questions jsonb
)
RETURNS SETOF public.survey_questions
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $save_survey$
DECLARE
  v_uid uuid := auth.uid();
  v_owner uuid;
  v_size int;
  v_i int;
  v_item jsonb;
  v_id uuid;
  v_type text;
  v_title text;
  v_desc text;
  v_options jsonb;
  v_required boolean;
  v_incoming_ids uuid[];
  v_invalid_count int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  SELECT manager_id INTO v_owner FROM public.surveys WHERE id = p_survey_id;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION '问卷不存在' USING ERRCODE = 'P0002';
  END IF;
  IF v_owner <> v_uid THEN
    RAISE EXCEPTION '仅问卷创建者可修改题目' USING ERRCODE = '42501';
  END IF;

  IF jsonb_typeof(p_questions) <> 'array' THEN
    RAISE EXCEPTION 'p_questions 必须是 JSON 数组' USING ERRCODE = '22023';
  END IF;

  v_size := jsonb_array_length(p_questions);
  IF v_size = 0 THEN
    RAISE EXCEPTION '至少保留一道题目' USING ERRCODE = 'P0001';
  END IF;
  IF v_size > 100 THEN
    RAISE EXCEPTION '题目数量超过上限（最多 100 题）' USING ERRCODE = 'P0001';
  END IF;

  SELECT ARRAY(
    SELECT (elem->>'id')::uuid
    FROM jsonb_array_elements(p_questions) AS elem
    WHERE elem->>'id' IS NOT NULL AND elem->>'id' <> ''
  ) INTO v_incoming_ids;

  IF array_length(v_incoming_ids, 1) IS NOT NULL THEN
    SELECT count(*) INTO v_invalid_count
      FROM unnest(v_incoming_ids) AS incoming(id)
      WHERE NOT EXISTS (
        SELECT 1 FROM public.survey_questions q
        WHERE q.id = incoming.id AND q.survey_id = p_survey_id
      );
    IF v_invalid_count > 0 THEN
      RAISE EXCEPTION '题目 ID 不属于此问卷' USING ERRCODE = '42501';
    END IF;
  END IF;

  DELETE FROM public.survey_questions
   WHERE survey_id = p_survey_id
     AND (v_incoming_ids IS NULL
          OR array_length(v_incoming_ids, 1) IS NULL
          OR id <> ALL (v_incoming_ids));

  FOR v_i IN 0..(v_size - 1) LOOP
    v_item := p_questions -> v_i;
    v_type := TRIM(COALESCE(v_item->>'question_type', ''));
    v_title := TRIM(COALESCE(v_item->>'title', ''));
    v_desc := COALESCE(v_item->>'description', '');
    v_options := COALESCE(v_item->'options', '{}'::jsonb);
    v_required := COALESCE((v_item->>'is_required')::boolean, true);

    IF v_type NOT IN (
      'basic_info','text_short','text_long','single_choice',
      'multi_choice','true_false','file_upload'
    ) THEN
      RAISE EXCEPTION '第 % 题：无效的题目类型 "%"', v_i + 1, v_type
        USING ERRCODE = '22023';
    END IF;
    IF v_title = '' THEN
      RAISE EXCEPTION '第 % 题：标题不能为空', v_i + 1 USING ERRCODE = '22023';
    END IF;

    v_id := NULLIF(v_item->>'id', '')::uuid;

    IF v_id IS NULL THEN
      INSERT INTO public.survey_questions (
        survey_id, question_type, title, description, options, is_required, display_order
      ) VALUES (
        p_survey_id, v_type, v_title, v_desc, v_options, v_required, v_i
      );
    ELSE
      UPDATE public.survey_questions
         SET question_type = v_type,
             title = v_title,
             description = v_desc,
             options = v_options,
             is_required = v_required,
             display_order = v_i
       WHERE id = v_id AND survey_id = p_survey_id;
    END IF;
  END LOOP;

  UPDATE public.surveys SET updated_at = now() WHERE id = p_survey_id;

  RETURN QUERY
    SELECT * FROM public.survey_questions
     WHERE survey_id = p_survey_id
     ORDER BY display_order, created_at;
END;
$save_survey$;

REVOKE ALL ON FUNCTION public.save_survey_questions(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_survey_questions(uuid, jsonb) TO authenticated;

-- ---------- 2) assign_survey_to_clients ----------
CREATE OR REPLACE FUNCTION public.assign_survey_to_clients(
  p_survey_id uuid,
  p_client_user_ids uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $assign$
DECLARE
  v_uid uuid := auth.uid();
  v_manager_role public.user_role;
  v_manager_disabled boolean;
  v_survey public.surveys%ROWTYPE;
  v_client_ids uuid[];
  v_client_id uuid;
  v_new_id uuid;
  v_assigned_count int := 0;
  v_skipped_count int := 0;
  v_notified_count int := 0;
  v_notify_ok boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  SELECT role, is_disabled INTO v_manager_role, v_manager_disabled
    FROM public.profiles WHERE id = v_uid;
  IF v_manager_role IS NULL THEN
    RAISE EXCEPTION '账号信息缺失' USING ERRCODE = 'P0002';
  END IF;
  IF COALESCE(v_manager_disabled, false) = true THEN
    RAISE EXCEPTION '账号已停用，无法发放问卷' USING ERRCODE = '42501';
  END IF;
  IF v_manager_role NOT IN ('manager'::public.user_role, 'admin'::public.user_role) THEN
    RAISE EXCEPTION '仅管理师可发放问卷' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_survey FROM public.surveys WHERE id = p_survey_id;
  IF v_survey.id IS NULL THEN
    RAISE EXCEPTION '问卷不存在' USING ERRCODE = 'P0002';
  END IF;
  IF v_survey.manager_id <> v_uid THEN
    RAISE EXCEPTION '仅问卷创建者可发放' USING ERRCODE = '42501';
  END IF;
  IF v_survey.status <> 'active'::public.survey_status THEN
    RAISE EXCEPTION '仅进行中的问卷可发放' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.survey_questions WHERE survey_id = p_survey_id) THEN
    RAISE EXCEPTION '问卷至少需要一道题目才能发放' USING ERRCODE = 'P0001';
  END IF;

  IF p_client_user_ids IS NULL OR array_length(p_client_user_ids, 1) IS NULL THEN
    RAISE EXCEPTION '请选择至少一位客户' USING ERRCODE = '22023';
  END IF;
  IF array_length(p_client_user_ids, 1) > 100 THEN
    RAISE EXCEPTION '单次最多可发放给 100 位客户' USING ERRCODE = '22023';
  END IF;

  SELECT ARRAY(SELECT DISTINCT x FROM unnest(p_client_user_ids) x WHERE x IS NOT NULL)
    INTO v_client_ids;

  FOREACH v_client_id IN ARRAY v_client_ids LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.client_relations
       WHERE manager_id = v_uid
         AND client_id = v_client_id
         AND status = 'active'
    ) THEN
      v_skipped_count := v_skipped_count + 1;
      CONTINUE;
    END IF;

    v_new_id := NULL;
    INSERT INTO public.survey_assignments (survey_id, client_user_id, manager_id)
    VALUES (p_survey_id, v_client_id, v_uid)
    ON CONFLICT ON CONSTRAINT survey_assignments_unique_pair DO NOTHING
    RETURNING id INTO v_new_id;

    IF v_new_id IS NOT NULL THEN
      v_assigned_count := v_assigned_count + 1;

      SELECT COALESCE((notification_settings->>'survey')::boolean, true)
        INTO v_notify_ok
        FROM public.profiles WHERE id = v_client_id;

      IF v_notify_ok IS TRUE THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_client_id,
          'survey_assigned',
          '收到新问卷',
          v_survey.title,
          jsonb_build_object(
            'surveyId', p_survey_id,
            'shareCode', v_survey.share_code,
            'assignmentId', v_new_id
          )
        );
        v_notified_count := v_notified_count + 1;
      END IF;
    ELSE
      v_skipped_count := v_skipped_count + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'assignedCount', v_assigned_count,
    'skippedCount',  v_skipped_count,
    'notifiedCount', v_notified_count
  );
END;
$assign$;

REVOKE ALL ON FUNCTION public.assign_survey_to_clients(uuid, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assign_survey_to_clients(uuid, uuid[]) TO authenticated;

-- ---------- 3) mark_notification_read（单条） ----------
CREATE OR REPLACE FUNCTION public.mark_notification_read(p_notification_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $mark_one$
DECLARE
  v_uid uuid := auth.uid();
  v_updated int;
BEGIN
  IF v_uid IS NULL THEN
    RETURN false;
  END IF;
  UPDATE public.notifications
     SET read_at = now()
   WHERE id = p_notification_id
     AND user_id = v_uid
     AND read_at IS NULL;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated > 0;
END;
$mark_one$;

REVOKE ALL ON FUNCTION public.mark_notification_read(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_notification_read(uuid) TO authenticated;

-- ---------- 4) mark_all_notifications_read ----------
CREATE OR REPLACE FUNCTION public.mark_all_notifications_read()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $mark_all$
DECLARE
  v_uid uuid := auth.uid();
  v_updated int;
BEGIN
  IF v_uid IS NULL THEN
    RETURN 0;
  END IF;
  UPDATE public.notifications
     SET read_at = now()
   WHERE user_id = v_uid AND read_at IS NULL;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END;
$mark_all$;

REVOKE ALL ON FUNCTION public.mark_all_notifications_read() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_all_notifications_read() TO authenticated;

-- ---------- 5) 历史 response_count 校准（幂等） ----------
UPDATE public.surveys s
   SET response_count = COALESCE(sub.cnt, 0),
       updated_at = updated_at
  FROM (
    SELECT survey_id, COUNT(*)::int AS cnt
      FROM public.survey_responses
     GROUP BY survey_id
  ) sub
 WHERE s.id = sub.survey_id
   AND s.response_count IS DISTINCT FROM sub.cnt;