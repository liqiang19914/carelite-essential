-- 提交评估：额外把「企业根」与「提交当时的题目」写进快照
--
-- 为什么要存题目快照：后台之后改了题干或选项文字，历史答卷若读当前模板展示，
-- 就会把用户当时看到的题目标错。快照保证旧报告永远按当时的措辞回显。
CREATE OR REPLACE FUNCTION public.submit_diet_map_assessment(
  p_template_id uuid,
  p_record_id uuid,
  p_answers jsonb,
  p_prefill_meta jsonb DEFAULT '{}'::jsonb,
  p_source_composition_id uuid DEFAULT NULL,
  p_mp_manager uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_access jsonb;
  v_tpl public.diet_map_templates%ROWTYPE;
  v_q jsonb;
  v_idx int := 0;
  v_qcode text;
  v_qtitle text;
  v_qtype text;
  v_required boolean;
  v_multiline boolean;
  v_limit int;
  v_answer text;
  v_clean jsonb := '{}'::jsonb;
  v_score jsonb;
  v_status text;
  v_type text;
  v_id uuid;
  v_manager uuid;
  v_root uuid;
  v_composition uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再提交评估' USING ERRCODE = '28000';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.health_records hr WHERE hr.id = p_record_id AND hr.user_id = v_uid
  ) THEN
    RAISE EXCEPTION '找不到这份健康档案，或它不属于当前账号' USING ERRCODE = '42501';
  END IF;

  v_access := public.get_my_diet_map_access(p_mp_manager, p_record_id);

  IF NOT COALESCE((v_access ->> 'open')::boolean, false) THEN
    RAISE EXCEPTION '你所在的商户尚未开放健康饮食导图' USING ERRCODE = '42501';
  END IF;

  IF (v_access -> 'template' ->> 'id')::uuid <> p_template_id THEN
    RAISE EXCEPTION '题目版本已更新，请退出重新进入后再作答' USING ERRCODE = '40001';
  END IF;

  SELECT * INTO v_tpl FROM public.diet_map_templates WHERE id = p_template_id;

  IF jsonb_typeof(COALESCE(p_answers, 'null'::jsonb)) <> 'object' THEN
    RAISE EXCEPTION '作答内容格式不正确，请退出重新作答' USING ERRCODE = '22023';
  END IF;

  FOR v_q IN SELECT value FROM jsonb_array_elements(COALESCE(v_tpl.questions, '[]'::jsonb)) LOOP
    v_idx := v_idx + 1;
    v_qcode := NULLIF(btrim(COALESCE(v_q ->> 'code', '')), '');
    CONTINUE WHEN v_qcode IS NULL;

    v_qtitle := COALESCE(NULLIF(btrim(COALESCE(v_q ->> 'title', '')), ''), v_qcode);
    v_qtype := COALESCE(NULLIF(v_q ->> 'type', ''), 'single');
    v_required := COALESCE((v_q ->> 'required')::boolean, v_qtype = 'single');
    v_multiline := COALESCE((v_q ->> 'multiline')::boolean, false);
    v_answer := NULLIF(btrim(COALESCE(p_answers ->> v_qcode, '')), '');

    IF v_answer IS NULL THEN
      IF v_required THEN
        RAISE EXCEPTION '第 % 项「%」还没有作答', v_idx, v_qtitle USING ERRCODE = '22023';
      END IF;
      CONTINUE;
    END IF;

    -- 多行补充说明题给到 500 字，其余仍按 200 字
    v_limit := CASE WHEN v_multiline THEN 500 ELSE 200 END;
    IF length(v_answer) > v_limit THEN
      RAISE EXCEPTION '第 % 项「%」填写内容过长，请精简到 % 字以内', v_idx, v_qtitle, v_limit USING ERRCODE = '22023';
    END IF;

    IF v_qtype = 'single' THEN
      IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(COALESCE(v_q -> 'options', '[]'::jsonb)) o
         WHERE o.value ->> 'code' = v_answer
      ) THEN
        RAISE EXCEPTION '第 % 项「%」的选项无效，请重新选择', v_idx, v_qtitle USING ERRCODE = '22023';
      END IF;
    ELSIF v_qtype = 'number' THEN
      IF v_answer !~ '^-?[0-9]+(\.[0-9]+)?$' THEN
        RAISE EXCEPTION '第 % 项「%」需要填写数字', v_idx, v_qtitle USING ERRCODE = '22023';
      END IF;
    END IF;

    v_clean := v_clean || jsonb_build_object(v_qcode, v_answer);
  END LOOP;

  v_score := public.diet_map_compute_score(
    v_tpl.questions, v_tpl.scoring, v_clean, v_tpl.scoring_confirmed
  );
  v_status := v_score ->> 'status';
  v_type := COALESCE(v_score ->> 'type_code', '');

  v_manager := NULLIF(v_access ->> 'manager_id', '')::uuid;
  v_root := NULLIF(v_access ->> 'root_manager_id', '')::uuid;

  IF p_source_composition_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.body_compositions bc
     WHERE bc.id = p_source_composition_id AND bc.record_id = p_record_id
  ) THEN
    v_composition := p_source_composition_id;
  END IF;

  INSERT INTO public.diet_map_assessments (
    template_id, config_version, user_id, record_id, manager_id,
    answers, status, type_code, scores, report_snapshot, prefill_meta, source_composition_id
  ) VALUES (
    p_template_id, v_tpl.config_version, v_uid, p_record_id, v_manager,
    v_clean, v_status, v_type, v_score -> 'scores',
    jsonb_build_object(
      'report', v_tpl.report,
      'questions', v_tpl.questions,
      'root_manager_id', v_root,
      'type_code', v_type,
      'snapshot_at', now()
    ),
    CASE WHEN jsonb_typeof(COALESCE(p_prefill_meta, 'null'::jsonb)) = 'object'
         THEN p_prefill_meta ELSE '{}'::jsonb END,
    v_composition
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'assessment_id', v_id,
    'status', v_status,
    'type_code', v_type,
    'scores', v_score -> 'scores',
    'tied', v_score -> 'tied'
  );
END;
$$;

-- 批量重评：刷新六型文案与分型结论，但**保留提交当时的题目快照**
CREATE OR REPLACE FUNCTION public.admin_rescore_diet_map(
  p_template_id uuid,
  p_force boolean DEFAULT false,
  p_limit int DEFAULT 500
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tpl public.diet_map_templates%ROWTYPE;
  v_limit int;
  v_row record;
  v_score jsonb;
  v_status text;
  v_type text;
  v_questions jsonb;
  v_root text;
  v_scanned int := 0;
  v_scored int := 0;
  v_pending_config int := 0;
  v_pending_tie int := 0;
  v_notified int := 0;
  v_remaining int := 0;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅平台管理员可批量重评' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_tpl FROM public.diet_map_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '饮食导图模板不存在' USING ERRCODE = 'P0002';
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 500), 1), 2000);

  FOR v_row IN
    SELECT a.id, a.status, a.answers, a.user_id, a.manager_id, a.report_snapshot
      FROM public.diet_map_assessments a
     WHERE a.template_id = p_template_id
       AND (COALESCE(p_force, false) OR a.status <> 'scored')
     ORDER BY a.submitted_at, a.id
     LIMIT v_limit
  LOOP
    v_scanned := v_scanned + 1;

    v_score := public.diet_map_compute_score(
      v_tpl.questions, v_tpl.scoring, v_row.answers, v_tpl.scoring_confirmed
    );
    v_status := v_score ->> 'status';
    v_type := COALESCE(v_score ->> 'type_code', '');

    -- 题目快照沿用提交当时的那份；只有历史行确实没有快照时才补当前模板
    v_questions := CASE
      WHEN jsonb_typeof(v_row.report_snapshot -> 'questions') = 'array'
        THEN v_row.report_snapshot -> 'questions'
      ELSE v_tpl.questions
    END;

    v_root := COALESCE(
      NULLIF(btrim(COALESCE(v_row.report_snapshot ->> 'root_manager_id', '')), ''),
      public.get_enterprise_root_manager_id(v_row.manager_id)::text
    );

    UPDATE public.diet_map_assessments
       SET status = v_status,
           type_code = v_type,
           scores = v_score -> 'scores',
           config_version = v_tpl.config_version,
           report_snapshot = jsonb_build_object(
             'report', v_tpl.report,
             'questions', v_questions,
             'root_manager_id', v_root,
             'type_code', v_type,
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
   WHERE a.template_id = p_template_id
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
$$;

COMMENT ON FUNCTION public.submit_diet_map_assessment(uuid, uuid, jsonb, jsonb, uuid, uuid) IS
  '提交饮食导图评估：校验开放状态、档案归属、必填与选项有效性后由服务端评分，落一行新历史。快照同时保存六型文案、提交当时的题目与所属企业根，保证历史报告的文字、题目措辞与圆心 Logo 都不随后台改动而变化。';
