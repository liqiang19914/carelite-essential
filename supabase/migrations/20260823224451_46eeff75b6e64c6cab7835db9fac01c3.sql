CREATE OR REPLACE FUNCTION public.validate_diet_map_config(p_template_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_tpl public.diet_map_templates%ROWTYPE;
  v_types text[] := ARRAY['S','D','G','N','C','A'];
  v_struct_gaps text[] := ARRAY[]::text[];
  v_scoring_gaps text[] := ARRAY[]::text[];
  v_report_gaps text[] := ARRAY[]::text[];
  v_codes text[] := ARRAY[]::text[];
  v_opt_codes text[];
  v_q jsonb;
  v_opt jsonb;
  v_idx int := 0;
  v_pos int := 0;
  v_header int := 0;
  v_qcode text;
  v_qtitle text;
  v_qtype text;
  v_qrole text;
  v_qlabel text;
  v_ocode text;
  v_single int := 0;
  v_opt_total int := 0;
  v_opt_covered int := 0;
  v_rt jsonb;
  v_meals jsonb;
  v_order jsonb;
  v_meal_n int;
  v_meal_filled int;
  v_meal_sum numeric;
  v_ord_total int;
  v_ord_uniq int;
  v_t text;
  v_scoring_status text;
  v_scoring jsonb;
  v_schema int;
  v_dim jsonb;
  v_qcodes jsonb;
  v_qcode_in_dim text;
  v_qcode_seen int;
  v_dim_seen int;
  v_score_val numeric;
  v_rules jsonb;
  v_rule jsonb;
  v_rule_ids text[] := ARRAY[]::text[];
  v_rule_id text;
  v_src jsonb;
  v_kind text;
  v_field text;
  v_rule_q text;
  v_op text;
  v_val jsonb;
  v_tbv jsonb;
  v_score_num numeric;
  v_vcfg jsonb;
  v_core_min numeric;
  v_sec_min numeric;
  v_sec_max numeric;
  v_bal_max numeric;
  v_max_primary int;
  v_max_secondary int;
  v_i int;
  v_img text;
  v_metric_fields text[] := ARRAY['gender','age','height','weight','bmi','bodyFatPercent','skeletalMusclePercent','skeletalMuscleKg','restingHeartRate','lipids','glucose','uricAcid'];
BEGIN
  IF NOT public.diet_map_can_manage_template(p_template_id, v_uid) THEN
    RAISE EXCEPTION '当前账号没有权限查看这份饮食导图配置' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_tpl FROM public.diet_map_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '饮食导图模板不存在' USING ERRCODE = 'P0002';
  END IF;

  -- ---------- 题目结构 ----------
  FOR v_q IN SELECT value FROM jsonb_array_elements(COALESCE(v_tpl.questions, '[]'::jsonb)) LOOP
    v_pos := v_pos + 1;
    v_qcode := NULLIF(btrim(COALESCE(v_q ->> 'code', '')), '');
    v_qtitle := NULLIF(btrim(COALESCE(v_q ->> 'title', '')), '');
    v_qtype := COALESCE(NULLIF(v_q ->> 'type', ''), 'single');
    v_qrole := COALESCE(NULLIF(v_q ->> 'role', ''), 'assessment');

    IF v_qrole NOT IN ('header', 'assessment') THEN
      v_struct_gaps := v_struct_gaps || format('第 %s 项（%s）的题目角色「%s」不受支持，只支持表头信息与正式题', v_pos, COALESCE(v_qcode, '无编码'), v_qrole);
      v_qrole := 'assessment';
    END IF;

    IF v_qrole = 'header' THEN
      v_header := v_header + 1;
    ELSE
      v_idx := v_idx + 1;
    END IF;

    IF v_qcode IS NULL THEN
      v_struct_gaps := v_struct_gaps || format('第 %s 项缺少题目编码', v_pos);
      CONTINUE;
    END IF;

    IF v_qcode = ANY(v_codes) THEN
      v_struct_gaps := v_struct_gaps || format('第 %s 项的题目编码「%s」与前面的题目重复', v_pos, v_qcode);
    ELSE
      v_codes := v_codes || v_qcode;
    END IF;

    IF v_qtitle IS NULL THEN
      v_struct_gaps := v_struct_gaps || format('第 %s 项（%s）缺少题干文字', v_pos, v_qcode);
    END IF;

    IF v_qtype NOT IN ('single', 'text', 'number', 'date') THEN
      v_struct_gaps := v_struct_gaps || format('第 %s 项（%s）的题型「%s」不受支持，只支持单选 / 文本 / 数字 / 日期', v_pos, v_qcode, v_qtype);
      CONTINUE;
    END IF;

    CONTINUE WHEN v_qtype <> 'single';

    IF jsonb_typeof(v_q -> 'options') <> 'array' OR jsonb_array_length(v_q -> 'options') < 2 THEN
      v_struct_gaps := v_struct_gaps || format('第 %s 项（%s）至少需要 2 个选项', v_pos, v_qcode);
      CONTINUE;
    END IF;

    v_opt_codes := ARRAY[]::text[];
    FOR v_opt IN SELECT value FROM jsonb_array_elements(v_q -> 'options') LOOP
      v_ocode := NULLIF(btrim(COALESCE(v_opt ->> 'code', '')), '');
      v_qlabel := COALESCE(NULLIF(btrim(COALESCE(v_opt ->> 'label', '')), ''), COALESCE(v_ocode, '未命名选项'));

      IF v_ocode IS NULL THEN
        v_struct_gaps := v_struct_gaps || format('第 %s 项（%s）的选项「%s」缺少选项编码', v_pos, v_qcode, v_qlabel);
      ELSIF v_ocode = ANY(v_opt_codes) THEN
        v_struct_gaps := v_struct_gaps || format('第 %s 项（%s）的选项编码「%s」重复', v_pos, v_qcode, v_ocode);
      ELSE
        v_opt_codes := v_opt_codes || v_ocode;
      END IF;

      IF NULLIF(btrim(COALESCE(v_opt ->> 'label', '')), '') IS NULL THEN
        v_struct_gaps := v_struct_gaps || format('第 %s 项（%s）的选项「%s」缺少选项文字', v_pos, v_qcode, COALESCE(v_ocode, '无编码'));
      END IF;
    END LOOP;

    CONTINUE WHEN v_qrole = 'header';
    v_single := v_single + 1;

    -- 正式单选必须 0/1/2 三个选项且带分值
    FOR v_opt IN SELECT value FROM jsonb_array_elements(v_q -> 'options') LOOP
      v_opt_total := v_opt_total + 1;
      v_ocode := NULLIF(btrim(COALESCE(v_opt ->> 'code', '')), '');
      IF v_ocode NOT IN ('0', '1', '2') THEN
        v_scoring_gaps := v_scoring_gaps || format('第 %s 题（%s）的选项编码「%s」不合规，新版体质问卷固定用 0/1/2 三档', v_idx, v_qcode, COALESCE(v_ocode, '无编码'));
        CONTINUE;
      END IF;
      v_score_val := (v_opt ->> 'scoreValue')::numeric;
      IF v_score_val IS NULL OR v_score_val <> v_ocode::numeric THEN
        v_scoring_gaps := v_scoring_gaps || format('第 %s 题（%s）的选项「%s」分值应为 %s', v_idx, v_qcode, COALESCE(NULLIF(btrim(COALESCE(v_opt ->> 'label', '')), ''), v_ocode), v_ocode);
      ELSE
        v_opt_covered := v_opt_covered + 1;
      END IF;
    END LOOP;
  END LOOP;

  IF v_pos = 0 THEN
    v_struct_gaps := v_struct_gaps || '尚未录入任何题目，请先导入或新增题目';
  ELSIF v_idx = 0 THEN
    v_struct_gaps := v_struct_gaps || '只有表头基本信息、没有任何正式题，无法据此分型';
  ELSIF v_idx <> 24 THEN
    v_struct_gaps := v_struct_gaps || format('正式题应为 24 题（六型各 4 题），当前是 %s 题', v_idx);
  END IF;

  -- ---------- 评分 v2 ----------
  v_scoring := v_tpl.scoring;
  v_schema := COALESCE((v_scoring ->> 'schemaVersion')::int, 1);
  IF v_schema < 2 THEN
    v_scoring_gaps := v_scoring_gaps || '评分规则还是旧版逐题权重格式，请先整体替换为新版体质问卷评分配置';
  ELSE
    -- 维度顺序必须是六型完整排列
    v_order := v_scoring -> 'dimensionOrder';
    IF jsonb_typeof(v_order) <> 'array' THEN
      v_scoring_gaps := v_scoring_gaps || '缺少六维排序（dimensionOrder）';
    ELSE
      SELECT count(*), count(DISTINCT x.code)
        INTO v_ord_total, v_ord_uniq
        FROM (SELECT value #>> '{}' AS code FROM jsonb_array_elements(v_order)) x
       WHERE x.code = ANY(v_types);

      IF jsonb_array_length(v_order) <> 6 OR v_ord_total <> 6 OR v_ord_uniq <> 6 THEN
        v_scoring_gaps := v_scoring_gaps || '六维排序（dimensionOrder）不是 S、D、G、N、C、A 六个型的完整不重复排列';
      END IF;
    END IF;

    -- 六维分组：每维恰好 4 题、24 题不重不漏
    v_dim_seen := 0;
    v_qcode_seen := 0;
    FOREACH v_t IN ARRAY v_types LOOP
      v_dim := v_scoring -> 'dimensions' -> v_t;
      IF v_dim IS NULL OR jsonb_typeof(v_dim) <> 'object' THEN
        v_scoring_gaps := v_scoring_gaps || format('%s 型缺少维度分组配置', v_t);
        CONTINUE;
      END IF;
      v_dim_seen := v_dim_seen + 1;
      v_qcodes := v_dim -> 'questionCodes';
      IF jsonb_typeof(v_qcodes) <> 'array' OR jsonb_array_length(v_qcodes) <> 4 THEN
        v_scoring_gaps := v_scoring_gaps || format('%s 型应恰好包含 4 道题', v_t);
        CONTINUE;
      END IF;
      FOR v_i IN 0 .. 3 LOOP
        v_qcode_in_dim := NULLIF(btrim(COALESCE(v_qcodes ->> v_i, '')), '');
        IF v_qcode_in_dim IS NULL OR NOT (v_qcode_in_dim = ANY(v_codes)) THEN
          v_scoring_gaps := v_scoring_gaps || format('%s 型引用了不存在的题目编码「%s」', v_t, COALESCE(v_qcode_in_dim, '空'));
        ELSE
          v_qcode_seen := v_qcode_seen + 1;
        END IF;
      END LOOP;
    END LOOP;

    IF v_dim_seen <> 6 THEN
      v_scoring_gaps := v_scoring_gaps || format('六维分组不完整（当前 %s 个）', v_dim_seen);
    END IF;
    IF v_qcode_seen <> 24 THEN
      v_scoring_gaps := v_scoring_gaps || format('六维分组覆盖的题目数应为 24，当前 %s 个（存在重复或遗漏）', v_qcode_seen);
    END IF;

    IF v_scoring -> 'answerScoring' ->> 'optionScoreField' <> 'scoreValue' THEN
      v_scoring_gaps := v_scoring_gaps || '选项计分字段配置缺失（应为 scoreValue）';
    END IF;

    -- 体测加权规则
    v_rules := v_scoring -> 'bonusRules';
    IF jsonb_typeof(v_rules) <> 'array' THEN
      v_scoring_gaps := v_scoring_gaps || '缺少体测加权规则（bonusRules）';
    ELSE
      FOR v_rule IN SELECT value FROM jsonb_array_elements(v_rules) LOOP
        v_rule_id := NULLIF(btrim(COALESCE(v_rule ->> 'id', '')), '');
        IF v_rule_id IS NULL THEN
          v_scoring_gaps := v_scoring_gaps || '存在缺少编号的体测加权规则';
        ELSIF v_rule_id = ANY(v_rule_ids) THEN
          v_scoring_gaps := v_scoring_gaps || format('体测加权规则编号「%s」重复', v_rule_id);
        ELSE
          v_rule_ids := v_rule_ids || v_rule_id;
        END IF;

        IF NOT (COALESCE(v_rule ->> 'dimension', '') = ANY(v_types)) THEN
          v_scoring_gaps := v_scoring_gaps || format('规则「%s」的维度不合法', COALESCE(v_rule_id, '无编号'));
        END IF;

        v_src := v_rule -> 'source';
        v_kind := COALESCE(v_src ->> 'kind', '');
        IF v_kind = 'answer' THEN
          v_rule_q := NULLIF(btrim(COALESCE(v_src ->> 'questionCode', '')), '');
          IF v_rule_q IS NULL OR NOT (v_rule_q = ANY(v_codes)) THEN
            v_scoring_gaps := v_scoring_gaps || format('规则「%s」引用了不存在的题目编码', COALESCE(v_rule_id, '无编号'));
          END IF;
        ELSIF v_kind = 'metric' THEN
          v_field := COALESCE(v_src ->> 'field', '');
          IF NOT (v_field = ANY(v_metric_fields)) THEN
            v_scoring_gaps := v_scoring_gaps || format('规则「%s」的指标「%s」不在白名单内', COALESCE(v_rule_id, '无编号'), COALESCE(v_field, '空'));
          END IF;
        ELSE
          v_scoring_gaps := v_scoring_gaps || format('规则「%s」的取值来源不合法', COALESCE(v_rule_id, '无编号'));
        END IF;

        v_op := COALESCE(v_rule ->> 'operator', '');
        IF NOT (v_op = ANY(ARRAY['eq','in','gt','gte','lt','lte'])) THEN
          v_scoring_gaps := v_scoring_gaps || format('规则「%s」的比较方式不合法', COALESCE(v_rule_id, '无编号'));
        END IF;

        v_val := v_rule -> 'value';
        v_tbv := v_rule -> 'thresholdByGender';
        IF v_op = 'in' THEN
          IF jsonb_typeof(v_val) <> 'array' OR jsonb_array_length(v_val) = 0 THEN
            v_scoring_gaps := v_scoring_gaps || format('规则「%s」用 in 比较时必须提供取值列表', COALESCE(v_rule_id, '无编号'));
          END IF;
        ELSIF v_op IN ('gt','gte','lt','lte') THEN
          IF (v_tbv IS NULL OR jsonb_typeof(v_tbv) <> 'object')
             AND NOT (COALESCE(v_rule ->> 'value', '') ~ '^-?[0-9]+(\.[0-9]+)?$') THEN
            v_scoring_gaps := v_scoring_gaps || format('规则「%s」缺少数值阈值', COALESCE(v_rule_id, '无编号'));
          END IF;
        ELSIF v_op = 'eq' THEN
          IF v_val IS NULL OR jsonb_typeof(v_val) = 'null' THEN
            v_scoring_gaps := v_scoring_gaps || format('规则「%s」缺少比较值', COALESCE(v_rule_id, '无编号'));
          END IF;
        END IF;

        v_score_num := (v_rule ->> 'score')::numeric;
        IF v_score_num IS NULL OR v_score_num <= 0 THEN
          v_scoring_gaps := v_scoring_gaps || format('规则「%s」的加分值必须为正数', COALESCE(v_rule_id, '无编号'));
        END IF;
      END LOOP;
    END IF;

    -- 判定阈值
    v_vcfg := v_scoring -> 'verdict';
    v_core_min := (v_vcfg ->> 'coreMin')::numeric;
    v_sec_min := (v_vcfg ->> 'secondaryMin')::numeric;
    v_sec_max := (v_vcfg ->> 'secondaryMax')::numeric;
    v_bal_max := (v_vcfg ->> 'balancedMax')::numeric;
    v_max_primary := COALESCE((v_vcfg ->> 'maxPrimary')::int, 0);
    v_max_secondary := COALESCE((v_vcfg ->> 'maxSecondary')::int, 0);
    IF v_core_min IS NULL OR v_sec_min IS NULL OR v_sec_max IS NULL OR v_bal_max IS NULL THEN
      v_scoring_gaps := v_scoring_gaps || '判定阈值不完整（核心线/辅助区间/平衡上限）';
    ELSIF v_sec_min > v_sec_max OR v_bal_max >= v_sec_min OR v_core_min <= v_sec_max THEN
      v_scoring_gaps := v_scoring_gaps || '判定阈值冲突：应为 平衡上限 < 辅助下限 ≤ 辅助上限 < 核心下限';
    END IF;
    IF v_max_primary < 1 OR v_max_primary > 6 THEN
      v_scoring_gaps := v_scoring_gaps || '核心体质数量上限应在 1-6 之间';
    END IF;
    IF v_max_secondary < 1 OR v_max_secondary > 6 THEN
      v_scoring_gaps := v_scoring_gaps || '辅助体质数量上限应在 1-6 之间';
    END IF;
  END IF;

  -- ---------- 报告内容 ----------
  FOREACH v_t IN ARRAY v_types LOOP
    v_rt := v_tpl.report -> 'types' -> v_t;
    IF v_rt IS NULL OR jsonb_typeof(v_rt) <> 'object' THEN
      v_report_gaps := v_report_gaps || format('%s 型的报告内容尚未录入', v_t);
      CONTINUE;
    END IF;
    IF NULLIF(btrim(COALESCE(v_rt ->> 'name', '')), '') IS NULL THEN
      v_report_gaps := v_report_gaps || format('%s 型缺少对外中文名称（顾客端不展示字母编码）', v_t);
    END IF;
    IF NULLIF(btrim(COALESCE(v_rt ->> 'analysis', '')), '') IS NULL THEN
      v_report_gaps := v_report_gaps || format('%s 型缺少「解析」文案', v_t);
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

    v_img := NULLIF(btrim(COALESCE(v_rt ->> 'dietGuideImageUrl', '')), '');
    IF v_img IS NOT NULL THEN
      IF left(v_img, 8) <> 'https://' THEN
        v_report_gaps := v_report_gaps || format('%s 型的饮食指南图片地址必须是 https 链接', v_t);
      END IF;
      IF NULLIF(btrim(COALESCE(v_rt ->> 'dietGuideImageStorageKey', '')), '') IS NULL THEN
        v_report_gaps := v_report_gaps || format('%s 型的饮食指南图片缺少存储标识', v_t);
      END IF;
    END IF;

    v_meals := v_rt -> 'meals';
    IF jsonb_typeof(v_meals) <> 'array' OR jsonb_array_length(v_meals) = 0 THEN
      v_report_gaps := v_report_gaps || format('%s 型缺少「餐次结构」', v_t);
    ELSE
      v_meal_n := jsonb_array_length(v_meals);
      IF v_meal_n > 8 THEN
        v_report_gaps := v_report_gaps
          || format('%s 型有 %s 个餐次格，超过 8 格上限后环上的字已无法阅读', v_t, v_meal_n);
      END IF;

      SELECT count(m.p), COALESCE(sum(m.p), 0)
        INTO v_meal_filled, v_meal_sum
        FROM (
          SELECT CASE
                   WHEN btrim(COALESCE(value ->> 'percent', '')) ~ '^-?[0-9]+(\.[0-9]+)?$'
                     THEN (value ->> 'percent')::numeric
                   ELSE NULL
                 END AS p
            FROM jsonb_array_elements(v_meals)
        ) m;

      IF v_meal_filled < v_meal_n THEN
        v_report_gaps := v_report_gaps
          || format('%s 型还有 %s 个餐次格没有填写占比', v_t, v_meal_n - v_meal_filled);
      ELSIF abs(v_meal_sum - 100) > 0.01 THEN
        v_report_gaps := v_report_gaps
          || format('%s 型的餐次占比合计 %s%%，与 100%% 不符，请对照客户原图核对', v_t, v_meal_sum);
      END IF;
    END IF;

    IF COALESCE(v_rt ->> 'confidence', '') = 'needs_review' THEN
      v_report_gaps := v_report_gaps || format('%s 型的文字来自原图转录，请对照客户原图核对后再改为「已核对」', v_t);
    END IF;
  END LOOP;

  IF v_schema < 2 THEN
    v_scoring_status := 'unconfigured';
  ELSIF COALESCE(array_length(v_scoring_gaps, 1), 0) > 0 OR v_opt_total = 0 OR v_opt_covered = 0 THEN
    v_scoring_status := 'partial';
  ELSE
    v_scoring_status := 'ready';
  END IF;

  RETURN jsonb_build_object(
    'template_id', v_tpl.id,
    'status', v_tpl.status,
    'config_version', v_tpl.config_version,
    'scoring_confirmed', v_tpl.scoring_confirmed,
    'scoring_status', v_scoring_status,
    'scoring_schema_version', v_schema,
    'question_count', v_idx,
    'header_count', v_header,
    'single_choice_count', v_single,
    'option_total', v_opt_total,
    'option_covered', v_opt_covered,
    'tie_break_set', false,
    'is_reference_weights', COALESCE((v_tpl.scoring ->> 'isReference')::boolean, false),
    'structure_gaps', to_jsonb(v_struct_gaps),
    'weight_gaps', to_jsonb(v_scoring_gaps),
    'report_gaps', to_jsonb(v_report_gaps),
    'publishable', COALESCE(array_length(v_struct_gaps, 1), 0) = 0,
    'confirmable', v_scoring_status = 'ready' AND COALESCE(array_length(v_report_gaps, 1), 0) = 0
  );
END;
$function$;

COMMENT ON FUNCTION public.validate_diet_map_config(uuid) IS
  '配置校验 v2：题目结构（12 表头 + 24 题）、评分 v2（六维各 4 题、选项 0/1/2 计分、体测加权 DSL 白名单、判定阈值）、报告（对外中文名、解析、所属系统、配色、特征、策略、餐次、指南图片地址）。publishable 只约束结构，confirmable 同时约束评分与报告。';