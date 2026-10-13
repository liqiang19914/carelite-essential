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
AS $function$
DECLARE
  v_types text[] := ARRAY['S','D','G','N','C','A'];
  v_order_arr text[];
  v_scores jsonb := '{}'::jsonb;
  v_t text;
  v_schema int;
  v_dims jsonb;
  v_qcodes jsonb;
  v_qcode text;
  v_q jsonb;
  v_qtype text;
  v_opt jsonb;
  v_ocode text;
  v_omap jsonb;
  v_qmap jsonb := '{}'::jsonb;
  v_ans text;
  v_base numeric;
  v_bonus numeric;
  v_cap numeric;
  v_rule jsonb;
  v_src jsonb;
  v_kind text;
  v_field text;
  v_rule_q text;
  v_op text;
  v_metric jsonb := '{}'::jsonb;
  v_inputs jsonb;
  v_input jsonb;
  v_key text;
  v_gender text := '';
  v_num numeric;
  v_tb numeric;
  v_tbv jsonb;
  v_dim_score numeric;
  v_max numeric := -1;
  v_second numeric;
  v_secs numeric[];
  v_primary text[] := ARRAY[]::text[];
  v_secondary text[] := ARRAY[]::text[];
  v_tops text[] := ARRAY[]::text[];
  v_sec_cand text[] := ARRAY[]::text[];
  v_overflow text[] := ARRAY[]::text[];
  v_verdict jsonb;
  v_type_code text := '';
  v_balanced boolean;
  v_matched int := 0;
  v_required_total int := 0;
  v_val_ok boolean;
  v_i int;
  v_core_min numeric;
  v_sec_min numeric;
  v_sec_max numeric;
  v_bal_max numeric;
  v_max_primary int;
  v_max_secondary int;
  v_include_rank2 boolean;
  v_promote_top boolean;
  v_verdict_cfg jsonb;
  v_muscle_kg numeric;
  v_weight_kg numeric;
  v_best_score numeric;
  v_pick text;
  v_pos_pick int;
  v_pos_t int;
BEGIN
  FOREACH v_t IN ARRAY v_types LOOP
    v_scores := v_scores || jsonb_build_object(v_t, 0);
  END LOOP;

  IF NOT COALESCE(p_scoring_confirmed, false) THEN
    RETURN jsonb_build_object('status', 'pending_config', 'type_code', '', 'scores', v_scores);
  END IF;

  IF p_scoring IS NULL OR jsonb_typeof(p_scoring) <> 'object' THEN
    RETURN jsonb_build_object('status', 'pending_config', 'type_code', '', 'scores', v_scores);
  END IF;

  v_schema := COALESCE((p_scoring ->> 'schemaVersion')::int, 1);
  IF v_schema < 2 THEN
    RETURN jsonb_build_object('status', 'pending_config', 'type_code', '', 'scores', v_scores, 'reason', 'legacy_scoring');
  END IF;

  v_dims := p_scoring -> 'dimensions';
  IF v_dims IS NULL OR jsonb_typeof(v_dims) <> 'object' THEN
    RETURN jsonb_build_object('status', 'pending_config', 'type_code', '', 'scores', v_scores, 'reason', 'bad_scoring');
  END IF;

  v_order_arr := ARRAY(
    SELECT jsonb_array_elements_text(COALESCE(p_scoring -> 'dimensionOrder', to_jsonb(v_types)))
  );

  FOR v_q IN SELECT value FROM jsonb_array_elements(COALESCE(p_questions, '[]'::jsonb)) LOOP
    v_qcode := NULLIF(btrim(COALESCE(v_q ->> 'code', '')), '');
    CONTINUE WHEN v_qcode IS NULL;
    v_qtype := COALESCE(NULLIF(v_q ->> 'type', ''), 'single');
    CONTINUE WHEN v_qtype <> 'single';
    CONTINUE WHEN COALESCE(NULLIF(v_q ->> 'role', ''), 'assessment') = 'header';
    v_omap := '{}'::jsonb;
    FOR v_opt IN SELECT value FROM jsonb_array_elements(COALESCE(v_q -> 'options', '[]'::jsonb)) LOOP
      v_ocode := NULLIF(btrim(COALESCE(v_opt ->> 'code', '')), '');
      CONTINUE WHEN v_ocode IS NULL;
      v_omap := v_omap || jsonb_build_object(v_ocode, COALESCE((v_opt ->> 'scoreValue')::numeric, 0));
    END LOOP;
    v_qmap := v_qmap || jsonb_build_object(v_qcode, v_omap);
  END LOOP;

  FOREACH v_t IN ARRAY v_types LOOP
    v_qcodes := v_dims -> v_t -> 'questionCodes';
    IF jsonb_typeof(v_qcodes) <> 'array' THEN
      RETURN jsonb_build_object('status', 'pending_config', 'type_code', '', 'scores', v_scores, 'reason', 'bad_scoring');
    END IF;

    v_base := 0;
    FOR v_i IN 0 .. jsonb_array_length(v_qcodes) - 1 LOOP
      v_qcode := v_qcodes ->> v_i;
      v_required_total := v_required_total + 1;
      v_ans := NULLIF(btrim(COALESCE(p_answers ->> v_qcode, '')), '');
      IF v_ans IS NOT NULL AND (v_qmap -> v_qcode) ? v_ans THEN
        v_matched := v_matched + 1;
        v_base := v_base + COALESCE((v_qmap -> v_qcode -> v_ans)::numeric, 0);
      END IF;
    END LOOP;
    v_scores := jsonb_set(v_scores, ARRAY[v_t], to_jsonb(v_base));
  END LOOP;

  IF v_matched < v_required_total THEN
    RETURN jsonb_build_object('status', 'pending_config', 'type_code', '', 'scores', v_scores, 'reason', 'incomplete_answers');
  END IF;

  v_inputs := p_scoring -> 'inputs';
  IF jsonb_typeof(v_inputs) = 'object' THEN
    FOR v_key IN SELECT jsonb_object_keys(v_inputs) LOOP
      v_input := v_inputs -> v_key;
      v_qcode := NULLIF(btrim(COALESCE(v_input ->> 'questionCode', '')), '');
      CONTINUE WHEN v_qcode IS NULL;
      v_ans := NULLIF(btrim(COALESCE(p_answers ->> v_qcode, '')), '');
      CONTINUE WHEN v_ans IS NULL;
      v_metric := v_metric || jsonb_build_object(v_key, v_ans);
    END LOOP;
  END IF;

  v_gender := COALESCE(v_metric ->> 'gender', '');

  IF NULLIF(btrim(COALESCE(v_metric ->> 'skeletalMusclePercent', '')), '') IS NULL THEN
    IF (v_metric ->> 'skeletalMuscleKg') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
      v_muscle_kg := (v_metric ->> 'skeletalMuscleKg')::numeric;
    END IF;
    IF (v_metric ->> 'weight') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
      v_weight_kg := (v_metric ->> 'weight')::numeric;
    END IF;
    IF v_muscle_kg IS NOT NULL AND v_muscle_kg > 0 AND v_weight_kg IS NOT NULL AND v_weight_kg > 0 THEN
      v_metric := v_metric || jsonb_build_object(
        'skeletalMusclePercent',
        round((v_muscle_kg / v_weight_kg * 100)::numeric, 1)::text
      );
    END IF;
  END IF;

  IF NULLIF(btrim(COALESCE(v_metric ->> 'bmi', '')), '') IS NULL THEN
    IF (v_metric ->> 'weight') ~ '^-?[0-9]+(\.[0-9]+)?$'
       AND (v_metric ->> 'height') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
      v_num := (v_metric ->> 'height')::numeric;
      IF v_num > 0 THEN
        v_metric := v_metric || jsonb_build_object(
          'bmi',
          round((((v_metric ->> 'weight')::numeric) / ((v_num / 100) * (v_num / 100)))::numeric, 1)::text
        );
      END IF;
    END IF;
  END IF;

  v_cap := COALESCE((p_scoring ->> 'measurementBonusCap')::numeric, 2);

  FOREACH v_t IN ARRAY v_types LOOP
    v_bonus := 0;
    FOR v_rule IN SELECT value FROM jsonb_array_elements(COALESCE(p_scoring -> 'bonusRules', '[]'::jsonb)) LOOP
      CONTINUE WHEN v_rule ->> 'dimension' <> v_t;
      v_src := v_rule -> 'source';
      v_kind := COALESCE(v_src ->> 'kind', '');
      v_op := COALESCE(v_rule ->> 'operator', '');
      v_val_ok := false;

      IF v_kind = 'answer' THEN
        v_rule_q := NULLIF(btrim(COALESCE(v_src ->> 'questionCode', '')), '');
        v_ans := NULLIF(btrim(COALESCE(p_answers ->> v_rule_q, '')), '');
        IF v_ans IS NOT NULL THEN
          IF v_op = 'eq' THEN
            v_val_ok := v_ans = COALESCE(v_rule ->> 'value', '');
          ELSIF v_op = 'in' THEN
            SELECT EXISTS (
              SELECT 1 FROM jsonb_array_elements_text(COALESCE(v_rule -> 'value', '[]'::jsonb)) x
               WHERE x = v_ans
            ) INTO v_val_ok;
          END IF;
        END IF;
      ELSIF v_kind = 'metric' THEN
        v_field := COALESCE(v_src ->> 'field', '');
        v_ans := NULLIF(btrim(COALESCE(v_metric ->> v_field, '')), '');
        IF v_ans IS NOT NULL THEN
          IF v_op = 'eq' THEN
            v_val_ok := v_ans = COALESCE(v_rule ->> 'value', '');
          ELSIF v_op = 'in' THEN
            SELECT EXISTS (
              SELECT 1 FROM jsonb_array_elements_text(COALESCE(v_rule -> 'value', '[]'::jsonb)) x
               WHERE x = v_ans
            ) INTO v_val_ok;
          ELSIF v_ans ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
            v_num := v_ans::numeric;
            v_tb := NULL;
            v_tbv := v_rule -> 'thresholdByGender';
            IF jsonb_typeof(v_tbv) = 'object' AND v_gender <> '' AND (v_tbv ? v_gender) THEN
              v_tb := NULLIF(v_tbv ->> v_gender, '')::numeric;
            END IF;
            IF v_tb IS NULL AND COALESCE(v_rule ->> 'value', '') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
              v_tb := (v_rule ->> 'value')::numeric;
            END IF;
            IF v_tb IS NOT NULL THEN
              IF v_op = 'gt' THEN
                v_val_ok := v_num > v_tb;
              ELSIF v_op = 'lt' THEN
                v_val_ok := v_num < v_tb;
              ELSIF v_op = 'gte' THEN
                IF COALESCE(v_rule ->> 'valueMax', '') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
                  v_val_ok := v_num >= v_tb AND v_num < (v_rule ->> 'valueMax')::numeric;
                ELSE
                  v_val_ok := v_num >= v_tb;
                END IF;
              ELSIF v_op = 'lte' THEN
                v_val_ok := v_num <= v_tb;
              END IF;
            END IF;
          END IF;
        END IF;
      END IF;

      IF v_val_ok THEN
        v_bonus := v_bonus + COALESCE((v_rule ->> 'score')::numeric, 0);
      END IF;
    END LOOP;

    v_bonus := LEAST(v_bonus, v_cap);
    v_scores := jsonb_set(
      v_scores,
      ARRAY[v_t],
      to_jsonb(COALESCE((v_scores ->> v_t)::numeric, 0) + v_bonus)
    );
  END LOOP;

  v_verdict_cfg := p_scoring -> 'verdict';
  v_core_min := COALESCE((v_verdict_cfg ->> 'coreMin')::numeric, 7);
  v_sec_min := COALESCE((v_verdict_cfg ->> 'secondaryMin')::numeric, 5);
  v_sec_max := COALESCE((v_verdict_cfg ->> 'secondaryMax')::numeric, 6.5);
  v_bal_max := COALESCE((v_verdict_cfg ->> 'balancedMax')::numeric, 4.5);
  v_max_primary := COALESCE((v_verdict_cfg ->> 'maxPrimary')::int, 2);
  v_max_secondary := COALESCE((v_verdict_cfg ->> 'maxSecondary')::int, 2);
  v_include_rank2 := COALESCE((v_verdict_cfg ->> 'includeSecondRankAsSecondary')::boolean, true);
  v_promote_top := COALESCE((v_verdict_cfg ->> 'promoteTopWhenNoCore')::boolean, true);

  SELECT bool_and(COALESCE((v_scores ->> t)::numeric, 0) <= v_bal_max)
    INTO v_balanced
    FROM unnest(v_types) t;

  IF COALESCE(v_balanced, false) THEN
    v_verdict := jsonb_build_object('schemaVersion', 1, 'primary', '[]'::jsonb, 'secondary', '[]'::jsonb, 'balanced', true);
    RETURN jsonb_build_object('status', 'scored', 'type_code', '', 'scores', v_scores, 'verdict', v_verdict);
  END IF;

  FOREACH v_t IN ARRAY v_types LOOP
    v_dim_score := COALESCE((v_scores ->> v_t)::numeric, 0);
    IF v_dim_score > v_max THEN
      v_max := v_dim_score;
    END IF;
  END LOOP;

  FOREACH v_t IN ARRAY v_types LOOP
    IF COALESCE((v_scores ->> v_t)::numeric, 0) = v_max THEN
      v_tops := v_tops || v_t;
    END IF;
  END LOOP;

  FOREACH v_t IN ARRAY v_tops LOOP
    IF COALESCE((v_scores ->> v_t)::numeric, 0) >= v_core_min THEN
      IF COALESCE(array_length(v_primary, 1), 0) < v_max_primary THEN
        v_primary := v_primary || v_t;
      ELSE
        v_overflow := v_overflow || v_t;
      END IF;
    END IF;
  END LOOP;

  IF COALESCE(array_length(v_primary, 1), 0) = 0 AND v_promote_top AND v_max >= v_sec_min THEN
    v_primary := ARRAY[v_tops[1]];
  END IF;

  SELECT array_agg(DISTINCT x.v ORDER BY x.v DESC)
    INTO v_secs
    FROM (SELECT COALESCE((v_scores ->> t)::numeric, 0) AS v FROM unnest(v_types) t) x;

  v_second := NULL;
  IF COALESCE(array_length(v_secs, 1), 0) >= 2 THEN
    v_second := v_secs[2];
  END IF;

  FOREACH v_t IN ARRAY v_types LOOP
    CONTINUE WHEN v_t = ANY(v_primary);
    v_dim_score := COALESCE((v_scores ->> v_t)::numeric, 0);
    IF (v_dim_score >= v_sec_min AND v_dim_score <= v_sec_max)
       OR v_t = ANY(v_overflow)
       OR (v_include_rank2 AND v_second IS NOT NULL AND v_second > 0 AND v_dim_score = v_second) THEN
      v_sec_cand := v_sec_cand || v_t;
    END IF;
  END LOOP;

  LOOP
    v_best_score := -1;
    v_pick := NULL;
    FOREACH v_t IN ARRAY v_sec_cand LOOP
      CONTINUE WHEN v_t = ANY(v_secondary);
      v_dim_score := COALESCE((v_scores ->> v_t)::numeric, 0);
      IF v_dim_score > v_best_score THEN
        v_best_score := v_dim_score;
        v_pick := v_t;
      ELSIF v_dim_score = v_best_score THEN
        v_pos_pick := COALESCE(array_position(v_order_arr, v_pick), 999);
        v_pos_t := COALESCE(array_position(v_order_arr, v_t), 999);
        IF v_pos_t < v_pos_pick THEN
          v_pick := v_t;
        END IF;
      END IF;
    END LOOP;
    EXIT WHEN v_pick IS NULL OR COALESCE(array_length(v_secondary, 1), 0) >= v_max_secondary;
    v_secondary := v_secondary || v_pick;
  END LOOP;

  IF COALESCE(array_length(v_primary, 1), 0) > 0 THEN
    v_type_code := v_primary[1];
  ELSIF COALESCE(array_length(v_secondary, 1), 0) > 0 THEN
    v_type_code := v_secondary[1];
  END IF;

  IF v_type_code = '' THEN
    v_verdict := jsonb_build_object('schemaVersion', 1, 'primary', '[]'::jsonb, 'secondary', '[]'::jsonb, 'balanced', true);
    RETURN jsonb_build_object('status', 'scored', 'type_code', '', 'scores', v_scores, 'verdict', v_verdict);
  END IF;

  v_verdict := jsonb_build_object(
    'schemaVersion', 1,
    'primary', to_jsonb(v_primary),
    'secondary', to_jsonb(v_secondary),
    'balanced', false
  );

  RETURN jsonb_build_object('status', 'scored', 'type_code', v_type_code, 'scores', v_scores, 'verdict', v_verdict);
END;
$function$;

COMMENT ON FUNCTION public.diet_map_compute_score(jsonb, jsonb, jsonb, boolean) IS
  '评分引擎 v2（纯函数）：六维各 4 题按选项 scoreValue(0/1/2) 计基础分，声明式体测加权（白名单字段/操作符/性别分阈值/区间上界，按维度封顶），判定核心(≥7 且最高，可双核心)/辅助(5-6.5 或排名第2且>0，最多2个)/平衡(全 ≤4.5)/无核心时最高分≥5 升为主展示型。BMI 与骨骼肌率缺失时由身高体重回退推导。未确认、旧版评分、作答不完整一律 pending_config 不出结论。';