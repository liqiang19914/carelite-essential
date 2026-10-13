CREATE OR REPLACE FUNCTION public.submit_diet_map_assessment(p_template_id uuid, p_record_id uuid, p_answers jsonb, p_prefill_meta jsonb DEFAULT '{}'::jsonb, p_source_composition_id uuid DEFAULT NULL::uuid, p_mp_manager uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  v_verdict jsonb;
  v_status text;
  v_type text;
  v_id uuid;
  v_manager uuid;
  v_root uuid;
  v_composition uuid;
  v_report jsonb;
  v_questions jsonb;
  v_h text;
  v_w text;
  v_bmi numeric;
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

  -- BMI 服务端重算：只信任身高/体重，覆盖浏览器提交的值
  v_h := NULLIF(btrim(COALESCE(v_clean ->> 'h_height', '')), '');
  v_w := NULLIF(btrim(COALESCE(v_clean ->> 'h_weight', '')), '');
  IF v_h IS NULL OR v_h !~ '^-?[0-9]+(\.[0-9]+)?$' THEN
    RAISE EXCEPTION '请先填写身高，BMI 会根据身高和体重自动计算' USING ERRCODE = '22023';
  END IF;
  IF v_w IS NULL OR v_w !~ '^-?[0-9]+(\.[0-9]+)?$' THEN
    RAISE EXCEPTION '请先填写体重，BMI 会根据身高和体重自动计算' USING ERRCODE = '22023';
  END IF;
  IF v_h::numeric < 50 OR v_h::numeric > 250 THEN
    RAISE EXCEPTION '身高数值不合理，请检查后重新填写' USING ERRCODE = '22023';
  END IF;
  IF v_w::numeric < 10 OR v_w::numeric > 350 THEN
    RAISE EXCEPTION '体重数值不合理，请检查后重新填写' USING ERRCODE = '22023';
  END IF;
  v_bmi := round((v_w::numeric / power(v_h::numeric / 100, 2))::numeric, 1);
  v_clean := jsonb_set(v_clean, '{h_bmi}', to_jsonb(v_bmi::text));

  v_score := public.diet_map_compute_score(
    v_tpl.questions, v_tpl.scoring, v_clean, v_tpl.scoring_confirmed
  );
  v_status := v_score ->> 'status';
  v_type := COALESCE(v_score ->> 'type_code', '');
  v_verdict := v_score -> 'verdict';

  v_manager := NULLIF(v_access ->> 'manager_id', '')::uuid;
  v_root := NULLIF(v_access ->> 'root_manager_id', '')::uuid;

  IF p_source_composition_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.body_compositions bc
     WHERE bc.id = p_source_composition_id AND bc.record_id = p_record_id
  ) THEN
    v_composition := p_source_composition_id;
  END IF;

  -- 报告快照使用访问接口返回的报告：已把商户缺的图片/名称/解析按平台参考版回退合并
  v_report := COALESCE(v_access -> 'template' -> 'report', v_tpl.report);
  v_questions := COALESCE(v_access -> 'template' -> 'questions', v_tpl.questions);

  INSERT INTO public.diet_map_assessments (
    template_id, config_version, user_id, record_id, manager_id, root_manager_id,
    answers, status, type_code, scores, verdict, report_snapshot, prefill_meta, source_composition_id
  ) VALUES (
    p_template_id, v_tpl.config_version, v_uid, p_record_id, v_manager, v_root,
    v_clean, v_status, v_type, v_score -> 'scores', v_verdict,
    jsonb_build_object(
      'report', v_report,
      'questions', v_questions,
      'root_manager_id', v_root,
      'type_code', v_type,
      'verdict', v_verdict,
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
    'verdict', v_verdict
  );
END;
$function$;

COMMENT ON FUNCTION public.submit_diet_map_assessment(uuid, uuid, jsonb, jsonb, uuid, uuid) IS
  '提交评估 v2：按模板逐题校验后，服务端用身高/体重重算 BMI 覆盖浏览器值，再调用评分引擎；报告快照使用访问接口合并过图片/名称/解析回退的报告，历史报告不随平台换图变化。';