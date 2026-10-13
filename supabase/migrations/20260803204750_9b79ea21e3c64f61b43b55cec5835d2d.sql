-- ============================================================================
-- 健康饮食导图：配置校验、发布、客户确认闸门
-- ============================================================================

-- 内部共用：声明式权重评分（submit / rescore 共用，避免两处算法漂移）
CREATE OR REPLACE FUNCTION public.diet_map_compute_score(
  p_questions jsonb,
  p_scoring jsonb,
  p_answers jsonb,
  p_scoring_confirmed boolean
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_types text[] := ARRAY['S','D','G','N','C','A'];
  v_weights jsonb;
  v_tie jsonb;
  v_scores jsonb := '{}'::jsonb;
  v_q jsonb;
  v_qcode text;
  v_answer text;
  v_ow jsonb;
  v_t text;
  v_total numeric := 0;
  v_cur numeric;
  v_max numeric := -1;
  v_tops text[] := ARRAY[]::text[];
  v_pick text;
  v_i int;
BEGIN
  FOREACH v_t IN ARRAY v_types LOOP
    v_scores := v_scores || jsonb_build_object(v_t, 0);
  END LOOP;

  IF NOT COALESCE(p_scoring_confirmed, false) THEN
    RETURN jsonb_build_object('status', 'pending_config', 'type_code', '', 'scores', v_scores);
  END IF;

  v_weights := p_scoring -> 'weights';
  IF v_weights IS NULL OR jsonb_typeof(v_weights) <> 'object' THEN
    RETURN jsonb_build_object('status', 'pending_config', 'type_code', '', 'scores', v_scores);
  END IF;

  FOR v_q IN SELECT value FROM jsonb_array_elements(COALESCE(p_questions, '[]'::jsonb)) LOOP
    v_qcode := NULLIF(btrim(COALESCE(v_q ->> 'code', '')), '');
    CONTINUE WHEN v_qcode IS NULL;
    CONTINUE WHEN COALESCE(NULLIF(v_q ->> 'type', ''), 'single') <> 'single';

    v_answer := NULLIF(btrim(COALESCE(p_answers ->> v_qcode, '')), '');
    CONTINUE WHEN v_answer IS NULL;

    v_ow := v_weights -> v_qcode -> v_answer;
    CONTINUE WHEN v_ow IS NULL OR jsonb_typeof(v_ow) <> 'object';

    FOREACH v_t IN ARRAY v_types LOOP
      v_scores := jsonb_set(
        v_scores,
        ARRAY[v_t],
        to_jsonb(
          COALESCE((v_scores ->> v_t)::numeric, 0)
          + COALESCE(NULLIF(v_ow ->> v_t, '')::numeric, 0)
        )
      );
    END LOOP;
  END LOOP;

  FOREACH v_t IN ARRAY v_types LOOP
    v_total := v_total + COALESCE((v_scores ->> v_t)::numeric, 0);
  END LOOP;

  IF v_total <= 0 THEN
    RETURN jsonb_build_object('status', 'pending_config', 'type_code', '', 'scores', v_scores);
  END IF;

  FOREACH v_t IN ARRAY v_types LOOP
    v_cur := COALESCE((v_scores ->> v_t)::numeric, 0);
    IF v_cur > v_max THEN
      v_max := v_cur;
      v_tops := ARRAY[v_t];
    ELSIF v_cur = v_max THEN
      v_tops := v_tops || v_t;
    END IF;
  END LOOP;

  IF COALESCE(array_length(v_tops, 1), 0) = 1 THEN
    RETURN jsonb_build_object('status', 'scored', 'type_code', v_tops[1], 'scores', v_scores);
  END IF;

  -- 平局：只认显式平局序，绝不按字母序兜底
  v_tie := p_scoring -> 'tieBreak';
  IF v_tie IS NOT NULL AND jsonb_typeof(v_tie) = 'array' AND jsonb_array_length(v_tie) > 0 THEN
    FOR v_i IN 0 .. jsonb_array_length(v_tie) - 1 LOOP
      v_pick := v_tie ->> v_i;
      IF v_pick = ANY(v_tops) THEN
        RETURN jsonb_build_object('status', 'scored', 'type_code', v_pick, 'scores', v_scores);
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'status', 'pending_tie', 'type_code', '', 'scores', v_scores, 'tied', to_jsonb(v_tops)
  );
END;
$$;

COMMENT ON FUNCTION public.diet_map_compute_score(jsonb, jsonb, jsonb, boolean) IS
  '纯函数：按声明式权重表计算六型得分。未经客户方确认、权重缺失或总分为 0 一律返回 pending_config；多型同分且无显式平局序返回 pending_tie，绝不按字母序兜底。';

-- 配置校验：题目结构 / 选项 / 权重完整度 / 六型报告内容，产出中文缺口清单
CREATE OR REPLACE FUNCTION public.validate_diet_map_config(p_template_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tpl public.diet_map_templates%ROWTYPE;
  v_types text[] := ARRAY['S','D','G','N','C','A'];
  v_struct_gaps text[] := ARRAY[]::text[];
  v_weight_gaps text[] := ARRAY[]::text[];
  v_report_gaps text[] := ARRAY[]::text[];
  v_codes text[] := ARRAY[]::text[];
  v_q jsonb;
  v_opt jsonb;
  v_idx int := 0;
  v_qcode text;
  v_qtitle text;
  v_qtype text;
  v_qlabel text;
  v_single int := 0;
  v_opt_total int := 0;
  v_opt_covered int := 0;
  v_w jsonb;
  v_ow jsonb;
  v_rt jsonb;
  v_t text;
  v_val text;
  v_ok boolean;
  v_scoring_status text;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅平台管理员可校验饮食导图配置' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_tpl FROM public.diet_map_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '饮食导图模板不存在' USING ERRCODE = 'P0002';
  END IF;

  FOR v_q IN SELECT value FROM jsonb_array_elements(COALESCE(v_tpl.questions, '[]'::jsonb)) LOOP
    v_idx := v_idx + 1;
    v_qcode := NULLIF(btrim(COALESCE(v_q ->> 'code', '')), '');
    v_qtitle := NULLIF(btrim(COALESCE(v_q ->> 'title', '')), '');
    v_qtype := COALESCE(NULLIF(v_q ->> 'type', ''), 'single');

    IF v_qcode IS NULL THEN
      v_struct_gaps := v_struct_gaps || format('第 %s 题缺少题目编码', v_idx);
      CONTINUE;
    END IF;

    IF v_qcode = ANY(v_codes) THEN
      v_struct_gaps := v_struct_gaps || format('第 %s 题的题目编码「%s」与前面的题目重复', v_idx, v_qcode);
    ELSE
      v_codes := v_codes || v_qcode;
    END IF;

    IF v_qtitle IS NULL THEN
      v_struct_gaps := v_struct_gaps || format('第 %s 题（%s）缺少题干文字', v_idx, v_qcode);
    END IF;

    IF v_qtype NOT IN ('single', 'text', 'number', 'date') THEN
      v_struct_gaps := v_struct_gaps || format('第 %s 题（%s）的题型「%s」不受支持，只支持单选 / 文本 / 数字 / 日期', v_idx, v_qcode, v_qtype);
      CONTINUE;
    END IF;

    CONTINUE WHEN v_qtype <> 'single';
    v_single := v_single + 1;

    IF jsonb_typeof(v_q -> 'options') <> 'array' OR jsonb_array_length(v_q -> 'options') < 2 THEN
      v_struct_gaps := v_struct_gaps || format('第 %s 题（%s）至少需要 2 个选项', v_idx, v_qcode);
      CONTINUE;
    END IF;

    v_w := v_tpl.scoring -> 'weights' -> v_qcode;

    FOR v_opt IN SELECT value FROM jsonb_array_elements(v_q -> 'options') LOOP
      v_opt_total := v_opt_total + 1;
      v_qlabel := COALESCE(NULLIF(btrim(COALESCE(v_opt ->> 'label', '')), ''), COALESCE(v_opt ->> 'code', '未命名选项'));

      IF NULLIF(btrim(COALESCE(v_opt ->> 'code', '')), '') IS NULL THEN
        v_struct_gaps := v_struct_gaps || format('第 %s 题（%s）的选项「%s」缺少选项编码', v_idx, v_qcode, v_qlabel);
        CONTINUE;
      END IF;

      IF NULLIF(btrim(COALESCE(v_opt ->> 'label', '')), '') IS NULL THEN
        v_struct_gaps := v_struct_gaps || format('第 %s 题（%s）的选项「%s」缺少选项文字', v_idx, v_qcode, v_opt ->> 'code');
      END IF;

      v_ow := CASE WHEN v_w IS NULL THEN NULL ELSE v_w -> (v_opt ->> 'code') END;
      IF v_ow IS NULL OR jsonb_typeof(v_ow) <> 'object' THEN
        v_weight_gaps := v_weight_gaps || format('第 %s 题（%s）的选项「%s」尚未设置六型权重', v_idx, v_qcode, v_qlabel);
        CONTINUE;
      END IF;

      v_ok := true;
      FOREACH v_t IN ARRAY v_types LOOP
        v_val := v_ow ->> v_t;
        IF v_val IS NULL OR btrim(v_val) = '' THEN
          v_ok := false;
          v_weight_gaps := v_weight_gaps || format('第 %s 题（%s）的选项「%s」缺少 %s 型权重', v_idx, v_qcode, v_qlabel, v_t);
        ELSIF v_val !~ '^-?[0-9]+(\.[0-9]+)?$' THEN
          v_ok := false;
          v_weight_gaps := v_weight_gaps || format('第 %s 题（%s）的选项「%s」的 %s 型权重「%s」不是数字', v_idx, v_qcode, v_qlabel, v_t, v_val);
        END IF;
      END LOOP;

      IF v_ok THEN
        v_opt_covered := v_opt_covered + 1;
      END IF;
    END LOOP;
  END LOOP;

  -- 六型报告内容完整度
  FOREACH v_t IN ARRAY v_types LOOP
    v_rt := v_tpl.report -> 'types' -> v_t;
    IF v_rt IS NULL OR jsonb_typeof(v_rt) <> 'object' THEN
      v_report_gaps := v_report_gaps || format('%s 型的报告内容尚未录入', v_t);
      CONTINUE;
    END IF;
    IF NULLIF(btrim(COALESCE(v_rt ->> 'system', '')), '') IS NULL THEN
      v_report_gaps := v_report_gaps || format('%s 型缺少「所属系统」', v_t);
    END IF;
    IF NULLIF(btrim(COALESCE(v_rt ->> 'color', '')), '') IS NULL THEN
      v_report_gaps := v_report_gaps || format('%s 型缺少扇区配色', v_t);
    END IF;
    IF jsonb_typeof(v_rt -> 'traits') <> 'array' OR jsonb_array_length(v_rt -> 'traits') = 0 THEN
      v_report_gaps := v_report_gaps || format('%s 型缺少「体质特征」', v_t);
    END IF;
    IF jsonb_typeof(v_rt -> 'strategy') <> 'array' OR jsonb_array_length(v_rt -> 'strategy') = 0 THEN
      v_report_gaps := v_report_gaps || format('%s 型缺少「饮食策略」', v_t);
    END IF;
    IF jsonb_typeof(v_rt -> 'meals') <> 'array' OR jsonb_array_length(v_rt -> 'meals') = 0 THEN
      v_report_gaps := v_report_gaps || format('%s 型缺少「餐次结构」', v_t);
    END IF;
    IF COALESCE(v_rt ->> 'confidence', '') = 'needs_review' THEN
      v_report_gaps := v_report_gaps || format('%s 型的文字来自原图转录，请对照客户原图核对后再改为「已核对」', v_t);
    END IF;
  END LOOP;

  IF v_opt_total = 0 OR v_opt_covered = 0 THEN
    v_scoring_status := 'unconfigured';
  ELSIF v_opt_covered < v_opt_total OR COALESCE(array_length(v_weight_gaps, 1), 0) > 0 THEN
    v_scoring_status := 'partial';
  ELSE
    v_scoring_status := 'ready';
  END IF;

  IF v_idx = 0 THEN
    v_struct_gaps := v_struct_gaps || '尚未录入任何题目，请先导入或新增题目';
  END IF;

  RETURN jsonb_build_object(
    'template_id', v_tpl.id,
    'status', v_tpl.status,
    'config_version', v_tpl.config_version,
    'scoring_confirmed', v_tpl.scoring_confirmed,
    'scoring_status', v_scoring_status,
    'question_count', v_idx,
    'single_choice_count', v_single,
    'option_total', v_opt_total,
    'option_covered', v_opt_covered,
    'tie_break_set', COALESCE(jsonb_typeof(v_tpl.scoring -> 'tieBreak') = 'array'
                              AND jsonb_array_length(v_tpl.scoring -> 'tieBreak') > 0, false),
    'is_reference_weights', COALESCE((v_tpl.scoring ->> 'isReference')::boolean, false),
    'structure_gaps', to_jsonb(v_struct_gaps),
    'weight_gaps', to_jsonb(v_weight_gaps),
    'report_gaps', to_jsonb(v_report_gaps),
    'publishable', COALESCE(array_length(v_struct_gaps, 1), 0) = 0,
    'confirmable', v_scoring_status = 'ready' AND COALESCE(array_length(v_report_gaps, 1), 0) = 0
  );
END;
$$;

-- 发布：结构无缺口即可发布，评分规则未确认也允许（此时评估落「待评定」）
CREATE OR REPLACE FUNCTION public.publish_diet_map_template(p_template_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_check jsonb;
  v_blocker text;
  v_version int;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅平台管理员可发布饮食导图' USING ERRCODE = '42501';
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
$$;

-- 客户确认闸门：未勾选时任何评估强制落 pending_config，不出任何饮食建议
CREATE OR REPLACE FUNCTION public.set_diet_map_scoring_confirmed(
  p_template_id uuid,
  p_confirmed boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_check jsonb;
  v_reason text;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅平台管理员可变更评分规则确认状态' USING ERRCODE = '42501';
  END IF;

  IF p_confirmed IS NULL THEN
    RAISE EXCEPTION '请指定要勾选还是取消勾选' USING ERRCODE = '22004';
  END IF;

  v_check := public.validate_diet_map_config(p_template_id);

  IF p_confirmed AND NOT COALESCE((v_check ->> 'confirmable')::boolean, false) THEN
    v_reason := COALESCE(
      v_check -> 'weight_gaps' ->> 0,
      v_check -> 'report_gaps' ->> 0,
      '评分规则或六型内容还不完整'
    );
    RAISE EXCEPTION '还不能勾选「已由客户方确认」：%', v_reason USING ERRCODE = '22023';
  END IF;

  UPDATE public.diet_map_templates
     SET scoring_confirmed = p_confirmed,
         scoring_confirmed_by = CASE WHEN p_confirmed THEN v_uid ELSE NULL END,
         scoring_confirmed_at = CASE WHEN p_confirmed THEN now() ELSE NULL END,
         updated_at = now()
   WHERE id = p_template_id;

  RETURN public.validate_diet_map_config(p_template_id);
END;
$$;

REVOKE ALL ON FUNCTION public.diet_map_compute_score(jsonb, jsonb, jsonb, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.validate_diet_map_config(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.publish_diet_map_template(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_diet_map_scoring_confirmed(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.validate_diet_map_config(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.publish_diet_map_template(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_diet_map_scoring_confirmed(uuid, boolean) TO authenticated;