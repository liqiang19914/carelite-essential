-- 配置校验：题目结构 / 选项编码 / 权重完整度 / 六型内容 / 扇区顺序 / 餐次比例
--
-- 刻意不在数据库里写死「25 题 8 项」：题量属于问卷版本，改版时不该让线上函数变成拦路石。
-- 题量核对放在后台编辑器里，与前端共用同一份原件常量；数据库只管与版本无关的结构正确性。
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
  v_w jsonb;
  v_ow jsonb;
  v_rt jsonb;
  v_meals jsonb;
  v_order jsonb;
  v_meal_n int;
  v_meal_filled int;
  v_meal_sum numeric;
  v_ord_total int;
  v_ord_uniq int;
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

    -- 选项编码必须是不重复的小写 a–e：客户方的评分规则按 A/B/C/D/E 写，编码不对就接不上
    v_opt_codes := ARRAY[]::text[];
    FOR v_opt IN SELECT value FROM jsonb_array_elements(v_q -> 'options') LOOP
      v_ocode := NULLIF(btrim(COALESCE(v_opt ->> 'code', '')), '');
      v_qlabel := COALESCE(NULLIF(btrim(COALESCE(v_opt ->> 'label', '')), ''), COALESCE(v_ocode, '未命名选项'));

      IF v_ocode IS NULL THEN
        v_struct_gaps := v_struct_gaps || format('第 %s 项（%s）的选项「%s」缺少选项编码', v_pos, v_qcode, v_qlabel);
      ELSIF v_ocode !~ '^[a-e]$' THEN
        v_struct_gaps := v_struct_gaps || format('第 %s 项（%s）的选项编码「%s」不合规，请用小写 a 至 e 与客户原件的 A/B/C/D/E 一一对应', v_pos, v_qcode, v_ocode);
      ELSIF v_ocode = ANY(v_opt_codes) THEN
        v_struct_gaps := v_struct_gaps || format('第 %s 项（%s）的选项编码「%s」重复', v_pos, v_qcode, v_ocode);
      ELSE
        v_opt_codes := v_opt_codes || v_ocode;
      END IF;

      IF NULLIF(btrim(COALESCE(v_opt ->> 'label', '')), '') IS NULL THEN
        v_struct_gaps := v_struct_gaps || format('第 %s 项（%s）的选项「%s」缺少选项文字', v_pos, v_qcode, COALESCE(v_ocode, '无编码'));
      END IF;
    END LOOP;

    -- 表头的单选（如性别）只做结构校验，不进权重统计
    CONTINUE WHEN v_qrole = 'header';
    v_single := v_single + 1;

    v_w := v_tpl.scoring -> 'weights' -> v_qcode;

    FOR v_opt IN SELECT value FROM jsonb_array_elements(v_q -> 'options') LOOP
      v_opt_total := v_opt_total + 1;
      v_qlabel := COALESCE(NULLIF(btrim(COALESCE(v_opt ->> 'label', '')), ''), COALESCE(v_opt ->> 'code', '未命名选项'));

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

  -- 六扇顺序：只认六个已知型的完整不重复排列，否则渲染时整组回退默认顺序
  v_order := v_tpl.report -> 'sectorOrder';
  IF v_order IS NOT NULL AND v_order <> 'null'::jsonb THEN
    IF jsonb_typeof(v_order) <> 'array' THEN
      v_report_gaps := v_report_gaps || '六扇顺序的格式不正确，应为形如 ["S","D","G","N","A","C"] 的数组';
    ELSE
      SELECT count(*), count(DISTINCT x.code)
        INTO v_ord_total, v_ord_uniq
        FROM (SELECT value #>> '{}' AS code FROM jsonb_array_elements(v_order)) x
       WHERE x.code = ANY(v_types);

      IF jsonb_array_length(v_order) <> 6 OR v_ord_total <> 6 OR v_ord_uniq <> 6 THEN
        v_report_gaps := v_report_gaps
          || '六扇顺序不是 S、D、G、N、C、A 六个型的完整不重复排列，轮盘会回退到默认顺序渲染';
      END IF;
    END IF;
  END IF;

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

  IF v_opt_total = 0 OR v_opt_covered = 0 THEN
    v_scoring_status := 'unconfigured';
  ELSIF v_opt_covered < v_opt_total OR COALESCE(array_length(v_weight_gaps, 1), 0) > 0 THEN
    v_scoring_status := 'partial';
  ELSE
    v_scoring_status := 'ready';
  END IF;

  IF v_pos = 0 THEN
    v_struct_gaps := v_struct_gaps || '尚未录入任何题目，请先导入或新增题目';
  ELSIF v_idx = 0 THEN
    v_struct_gaps := v_struct_gaps || '只有表头基本信息、没有任何正式题，无法据此分型';
  END IF;

  RETURN jsonb_build_object(
    'template_id', v_tpl.id,
    'status', v_tpl.status,
    'config_version', v_tpl.config_version,
    'scoring_confirmed', v_tpl.scoring_confirmed,
    'scoring_status', v_scoring_status,
    'question_count', v_idx,
    'header_count', v_header,
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

COMMENT ON FUNCTION public.validate_diet_map_config(uuid) IS
  '校验饮食导图配置：题目结构、选项编码必须是不重复的小写 a–e、正式题的六型权重完整度、六型内容、六扇顺序为完整排列、餐次格数不超 8 格且占比合计 100%。表头信息（role=header）只做结构校验，不参与权重统计。question_count 只统计正式题，header_count 单独统计。';
