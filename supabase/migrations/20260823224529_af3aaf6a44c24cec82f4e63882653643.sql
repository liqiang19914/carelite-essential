CREATE OR REPLACE FUNCTION public.publish_diet_map_template(p_template_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_tpl public.diet_map_templates%ROWTYPE;
  v_check jsonb;
  v_blocker text;
  v_version int;
BEGIN
  IF NOT public.diet_map_can_manage_template(p_template_id, v_uid) THEN
    RAISE EXCEPTION '当前账号没有权限发布这份饮食导图' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_tpl FROM public.diet_map_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '饮食导图模板不存在' USING ERRCODE = 'P0002';
  END IF;

  IF v_tpl.root_manager_id IS NULL AND NOT COALESCE(v_tpl.scoring_confirmed, false) THEN
    RAISE EXCEPTION '平台参考版需要先确认评分规则，才能对外发布' USING ERRCODE = '22023';
  END IF;

  v_check := public.validate_diet_map_config(p_template_id);

  IF NOT COALESCE((v_check ->> 'publishable')::boolean, false) THEN
    v_blocker := COALESCE(v_check -> 'structure_gaps' ->> 0, '题目配置不完整');
    RAISE EXCEPTION '题目配置还不能发布：%', v_blocker USING ERRCODE = '22023';
  END IF;

  UPDATE public.diet_map_templates
     SET status = 'published',
         config_version = config_version + 1,
         updated_at = now()
   WHERE id = p_template_id
  RETURNING config_version INTO v_version;

  RETURN v_check
    || jsonb_build_object('status', 'published', 'config_version', v_version);
END;
$function$;

COMMENT ON FUNCTION public.publish_diet_map_template(uuid) IS
  '发布 v2：平台参考版必须先确认评分；商户副本可先发布草稿内容，但访问接口只认「已发布且已确认」，未确认时客户继续读平台版。';

CREATE OR REPLACE FUNCTION public.ensure_my_diet_map_template()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_ref public.diet_map_templates%ROWTYPE;
  v_own_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;

  IF NOT public.is_enterprise_admin(v_uid) THEN
    RAISE EXCEPTION '只有企业主或企业管理员可以配置饮食导图' USING ERRCODE = '42501';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号还没有归属企业，无法配置饮食导图' USING ERRCODE = '42501';
  END IF;

  -- 授权始终指向平台参考版
  SELECT t.* INTO v_ref
    FROM public.diet_map_templates t
    JOIN public.diet_map_grants g ON g.template_id = t.id
   WHERE g.root_manager_id = v_root
     AND g.is_enabled = true
     AND t.root_manager_id IS NULL
   ORDER BY g.granted_at DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('granted', false, 'root_manager_id', v_root);
  END IF;

  SELECT t.id INTO v_own_id
    FROM public.diet_map_templates t
   WHERE t.root_manager_id = v_root
     AND t.source_template_id = v_ref.id
   LIMIT 1;

  IF v_own_id IS NULL THEN
    -- 新版副本默认「评分未确认」：内容与参考版一致，但必须商户在本店确认评分后，
    -- 发布才对全店客户生效；未确认/未发布期间客户始终读平台参考版。
    INSERT INTO public.diet_map_templates (
      map_key, title, description, status,
      questions, scoring, report,
      config_version, scoring_confirmed, scoring_confirmed_by, scoring_confirmed_at,
      root_manager_id, source_template_id, created_by
    ) VALUES (
      v_ref.map_key, v_ref.title, v_ref.description, 'draft',
      v_ref.questions, v_ref.scoring, v_ref.report,
      1, false, NULL, NULL,
      v_root, v_ref.id, v_uid
    )
    ON CONFLICT (root_manager_id, source_template_id)
      WHERE root_manager_id IS NOT NULL
      DO NOTHING
    RETURNING id INTO v_own_id;

    IF v_own_id IS NULL THEN
      SELECT t.id INTO v_own_id
        FROM public.diet_map_templates t
       WHERE t.root_manager_id = v_root
         AND t.source_template_id = v_ref.id
       LIMIT 1;
    END IF;

    IF v_own_id IS NULL THEN
      RAISE EXCEPTION '本店的导图版本正在创建中，请稍后重新打开这个页面' USING ERRCODE = '40001';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'granted', true,
    'root_manager_id', v_root,
    'template_id', v_own_id,
    'reference_template_id', v_ref.id
  );
END;
$function$;

COMMENT ON FUNCTION public.ensure_my_diet_map_template() IS
  '商户副本 v2：内容随平台参考版复制，但评分默认未确认、状态草稿；商户确认并发布后才会对全店客户生效。';

CREATE OR REPLACE FUNCTION public.admin_rescore_diet_map(p_template_id uuid, p_force boolean DEFAULT false, p_limit integer DEFAULT 500)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_tpl public.diet_map_templates%ROWTYPE;
  v_limit int;
  v_row record;
  v_score jsonb;
  v_status text;
  v_type text;
  v_verdict jsonb;
  v_questions jsonb;
  v_scanned int := 0;
  v_scored int := 0;
  v_pending_config int := 0;
  v_pending_tie int := 0;
  v_notified int := 0;
  v_remaining int := 0;
BEGIN
  IF NOT public.diet_map_can_manage_template(p_template_id, v_uid) THEN
    RAISE EXCEPTION '当前账号没有权限批量重评这份饮食导图' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_tpl FROM public.diet_map_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '饮食导图模板不存在' USING ERRCODE = 'P0002';
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 500), 1), 2000);

  FOR v_row IN
    SELECT a.id, a.status, a.answers, a.user_id, a.manager_id, a.root_manager_id, a.report_snapshot
      FROM public.diet_map_assessments a
     WHERE (
             CASE WHEN v_tpl.root_manager_id IS NULL
                  THEN a.template_id = p_template_id
                       AND NOT EXISTS (
                             SELECT 1
                               FROM public.diet_map_templates m
                              WHERE m.root_manager_id = a.root_manager_id
                                AND m.source_template_id = p_template_id
                                AND m.status = 'published'
                           )
                  ELSE a.root_manager_id = v_tpl.root_manager_id
             END
           )
       -- 只处理尚未出结论的记录：已评定的历史结论（旧规则）一律保持原样
       AND a.status <> 'scored'
     ORDER BY a.submitted_at, a.id
     LIMIT v_limit
  LOOP
    v_scanned := v_scanned + 1;

    v_score := public.diet_map_compute_score(
      v_tpl.questions, v_tpl.scoring, v_row.answers, v_tpl.scoring_confirmed
    );
    v_status := v_score ->> 'status';
    v_type := COALESCE(v_score ->> 'type_code', '');
    v_verdict := v_score -> 'verdict';

    v_questions := CASE
      WHEN jsonb_typeof(v_row.report_snapshot -> 'questions') = 'array'
        THEN v_row.report_snapshot -> 'questions'
      ELSE v_tpl.questions
    END;

    UPDATE public.diet_map_assessments
       SET status = v_status,
           type_code = v_type,
           scores = v_score -> 'scores',
           verdict = v_verdict,
           config_version = v_tpl.config_version,
           report_snapshot = jsonb_build_object(
             'report', v_tpl.report,
             'questions', v_questions,
             'root_manager_id', COALESCE(
               v_row.root_manager_id,
               NULLIF(btrim(COALESCE(v_row.report_snapshot ->> 'root_manager_id', '')), '')::uuid,
               public.get_enterprise_root_manager_id(v_row.manager_id)
             ),
             'type_code', v_type,
             'verdict', v_verdict,
             'snapshot_at', now()
           )
     WHERE id = v_row.id;

    IF v_status = 'scored' THEN
      v_scored := v_scored + 1;
      IF v_row.status <> 'scored' THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_row.user_id,
          'diet_map_ready',
          '你的健康饮食导图已出结果',
          '评估结果已完成评定，点开可以查看你的体质分型与对应的饮食策略。',
          jsonb_build_object('assessment_id', v_row.id, 'type_code', v_type)
        );
        v_notified := v_notified + 1;
      END IF;
    ELSIF v_status = 'pending_tie' THEN
      v_pending_tie := v_pending_tie + 1;
    ELSE
      v_pending_config := v_pending_config + 1;
    END IF;
  END LOOP;

  SELECT count(*) INTO v_remaining
    FROM public.diet_map_assessments a
   WHERE (
           CASE WHEN v_tpl.root_manager_id IS NULL
                THEN a.template_id = p_template_id
                     AND NOT EXISTS (
                           SELECT 1
                             FROM public.diet_map_templates m
                            WHERE m.root_manager_id = a.root_manager_id
                              AND m.source_template_id = p_template_id
                              AND m.status = 'published'
                         )
                ELSE a.root_manager_id = v_tpl.root_manager_id
           END
         )
     AND a.status <> 'scored';

  RETURN jsonb_build_object(
    'scanned', v_scanned,
    'scored', v_scored,
    'pending_config', v_pending_config,
    'pending_tie', v_pending_tie,
    'notified', v_notified,
    'remaining_pending', v_remaining
  );
END;
$function$;

COMMENT ON FUNCTION public.admin_rescore_diet_map(uuid, boolean, int) IS
  '批量重评 v2：只处理 pending_config / pending_tie 记录，已评定（scored）的历史结论永不重写；新引擎对旧版答卷返回 pending_config 不出错。p_force 参数保留签名兼容，不再支持覆盖已评定记录。';