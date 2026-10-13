-- 审查修复：get_my_diet_map_access 恢复「已发布且已确认」闸门，latest 补输出 verdict
CREATE OR REPLACE FUNCTION public.get_my_diet_map_access(p_mp_manager uuid DEFAULT NULL::uuid, p_record_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_manager uuid;
  v_trusted boolean := false;
  v_ref public.diet_map_templates%ROWTYPE;
  v_tpl public.diet_map_templates%ROWTYPE;
  v_source text := 'reference';
  v_record uuid;
  v_latest jsonb := NULL;
  v_code text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再查看健康饮食导图' USING ERRCODE = '28000';
  END IF;

  IF p_mp_manager IS NOT NULL THEN
    v_root := public.get_enterprise_root_manager_id(p_mp_manager);
  END IF;

  IF v_root IS NOT NULL THEN
    SELECT cr.manager_id INTO v_manager
      FROM public.client_relations cr
      JOIN public.profiles mp ON mp.id = cr.manager_id
     WHERE cr.client_id = v_uid
       AND cr.status = 'active'
       AND mp.role = 'manager'
       AND COALESCE(mp.parent_manager_id, mp.id) = v_root
     ORDER BY (cr.manager_id = p_mp_manager) DESC, cr.created_at DESC, cr.id DESC
     LIMIT 1;
  ELSE
    SELECT cr.manager_id, COALESCE(mp.parent_manager_id, mp.id)
      INTO v_manager, v_root
      FROM public.client_relations cr
      JOIN public.profiles mp ON mp.id = cr.manager_id
     WHERE cr.client_id = v_uid
       AND cr.status = 'active'
       AND mp.role = 'manager'
     ORDER BY cr.created_at DESC, cr.id DESC
     LIMIT 1;
  END IF;

  IF v_root IS NULL THEN
    RETURN jsonb_build_object('open', false, 'reason', 'no_merchant');
  END IF;

  v_trusted := v_manager IS NOT NULL
    OR EXISTS (
      SELECT 1 FROM public.manager_miniprograms mm
       WHERE mm.manager_id = v_root AND mm.is_enabled = true
    );

  IF NOT v_trusted THEN
    RETURN jsonb_build_object('open', false, 'reason', 'no_merchant');
  END IF;

  -- 授权始终挂在平台参考版上
  SELECT t.* INTO v_ref
    FROM public.diet_map_templates t
    JOIN public.diet_map_grants g ON g.template_id = t.id
   WHERE g.root_manager_id = v_root
     AND g.is_enabled = true
     AND t.root_manager_id IS NULL
   ORDER BY g.granted_at DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('open', false, 'reason', 'not_granted', 'root_manager_id', v_root);
  END IF;

  -- 商户自己「已发布且已确认」的版本优先；发布但未确认的版本不能对客户生效
  SELECT t.* INTO v_tpl
    FROM public.diet_map_templates t
   WHERE t.root_manager_id = v_root
     AND t.source_template_id = v_ref.id
     AND t.status = 'published'
     AND t.scoring_confirmed = true
   LIMIT 1;

  IF FOUND THEN
    v_source := 'merchant';
  ELSE
    IF v_ref.status <> 'published' OR COALESCE(v_ref.scoring_confirmed, false) = false THEN
      RETURN jsonb_build_object('open', false, 'reason', 'not_granted', 'root_manager_id', v_root);
    END IF;
    v_tpl := v_ref;
    v_source := 'reference';
  END IF;

  -- 商户版报告合并：每个型的饮食指南长图（含存储键）、对外中文名、解析文案，
  -- 商户留空即回退平台参考版；其余内容尊重商户自己的编辑。
  IF v_source = 'merchant' THEN
    IF v_tpl.report -> 'types' IS NULL THEN
      v_tpl.report := jsonb_set(v_tpl.report, '{types}', '{}'::jsonb, true);
    END IF;
    FOREACH v_code IN ARRAY ARRAY['S','A','C','N','D','G'] LOOP
      IF NULLIF(btrim(v_tpl.report #>> ARRAY['types', v_code, 'dietGuideImageUrl']), '') IS NULL
         AND NULLIF(btrim(v_ref.report #>> ARRAY['types', v_code, 'dietGuideImageUrl']), '') IS NOT NULL THEN
        v_tpl.report := jsonb_set(
          v_tpl.report,
          ARRAY['types', v_code],
          COALESCE(v_tpl.report #> ARRAY['types', v_code], '{}'::jsonb) || jsonb_build_object(
            'dietGuideImageUrl', v_ref.report #>> ARRAY['types', v_code, 'dietGuideImageUrl'],
            'dietGuideImageStorageKey', COALESCE(v_ref.report #>> ARRAY['types', v_code, 'dietGuideImageStorageKey'], '')
          ),
          true
        );
      END IF;
      IF NULLIF(btrim(v_tpl.report #>> ARRAY['types', v_code, 'name']), '') IS NULL
         AND NULLIF(btrim(v_ref.report #>> ARRAY['types', v_code, 'name']), '') IS NOT NULL THEN
        v_tpl.report := jsonb_set(
          v_tpl.report,
          ARRAY['types', v_code],
          COALESCE(v_tpl.report #> ARRAY['types', v_code], '{}'::jsonb) || jsonb_build_object(
            'name', v_ref.report #>> ARRAY['types', v_code, 'name']
          ),
          true
        );
      END IF;
      IF NULLIF(btrim(v_tpl.report #>> ARRAY['types', v_code, 'analysis']), '') IS NULL
         AND NULLIF(btrim(v_ref.report #>> ARRAY['types', v_code, 'analysis']), '') IS NOT NULL THEN
        v_tpl.report := jsonb_set(
          v_tpl.report,
          ARRAY['types', v_code],
          COALESCE(v_tpl.report #> ARRAY['types', v_code], '{}'::jsonb) || jsonb_build_object(
            'analysis', v_ref.report #>> ARRAY['types', v_code, 'analysis']
          ),
          true
        );
      END IF;
    END LOOP;
  END IF;

  IF p_record_id IS NOT NULL THEN
    SELECT hr.id INTO v_record
      FROM public.health_records hr
     WHERE hr.id = p_record_id AND hr.user_id = v_uid;
  END IF;

  IF v_record IS NULL THEN
    SELECT hr.id INTO v_record
      FROM public.health_records hr
     WHERE hr.user_id = v_uid
     ORDER BY hr.is_default DESC, hr.created_at
     LIMIT 1;
  END IF;

  -- 历史按企业隔离：同一份档案在别家商户答过的记录不会串过来。
  -- 模板可能刚从参考版切到商户版，所以不按 template_id 而按企业根取最近一条。
  IF v_record IS NOT NULL THEN
    SELECT jsonb_build_object(
             'id', a.id,
             'status', a.status,
             'type_code', a.type_code,
             'verdict', a.verdict,
             'submitted_at', a.submitted_at,
             'record_id', a.record_id,
             'config_version', a.config_version
           )
      INTO v_latest
      FROM public.diet_map_assessments a
     WHERE a.record_id = v_record
       AND COALESCE(a.root_manager_id, v_root) = v_root
     ORDER BY a.submitted_at DESC, a.id DESC
     LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'open', true,
    'root_manager_id', v_root,
    'manager_id', v_manager,
    'record_id', v_record,
    'template_source', v_source,
    'template', jsonb_build_object(
      'id', v_tpl.id,
      'map_key', v_tpl.map_key,
      'title', v_tpl.title,
      'description', v_tpl.description,
      'config_version', v_tpl.config_version,
      'scoring_confirmed', v_tpl.scoring_confirmed,
      'questions', v_tpl.questions,
      'report', v_tpl.report
    ),
    'latest', v_latest
  );
END;
$function$;

-- 审查修复：并列最高时按 dimensionOrder 稳定顺序取核心（三重并列兜底），
-- 无核心升主展示型同样按维度顺序取首位；gt 区间上界 valueMax 生效。
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
  v_iter text[];
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
  v_max_val numeric;
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

  -- 兜底迭代顺序：配置的六维顺序优先，缺失的型按固定顺序补在尾部
  v_order_arr := ARRAY(
    SELECT jsonb_array_elements_text(COALESCE(p_scoring -> 'dimensionOrder', to_jsonb(v_types)))
  );
  v_iter := v_order_arr;
  FOREACH v_t IN ARRAY v_types LOOP
    IF NOT v_t = ANY(v_iter) THEN
      v_iter := v_iter || v_t;
    END IF;
  END LOOP;

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
                IF COALESCE(v_rule ->> 'valueMax', '') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
                  v_max_val := (v_rule ->> 'valueMax')::numeric;
                  v_val_ok := v_num > v_tb AND v_num < v_max_val;
                ELSE
                  v_val_ok := v_num > v_tb;
                END IF;
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

  FOREACH v_t IN ARRAY v_iter LOOP
    v_dim_score := COALESCE((v_scores ->> v_t)::numeric, 0);
    IF v_dim_score > v_max THEN
      v_max := v_dim_score;
    END IF;
  END LOOP;

  FOREACH v_t IN ARRAY v_iter LOOP
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

  FOREACH v_t IN ARRAY v_iter LOOP
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