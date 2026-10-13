
-- 为李强创建健康档案并生成一年的每周体征测试数据
-- 基线数据来源：2025-03-05 北京爱康国宾体检报告

DO $$
DECLARE
  v_record_id uuid := gen_random_uuid();
  v_user_id uuid := '477ffa51-fa1f-42ca-9944-745bb7a8d971';
  v_current_date timestamptz;
  v_week_index int := 0;
  v_seasonal float;
  v_heart_rate int;
  v_systolic int;
  v_diastolic int;
  v_blood_sugar numeric(4,2);
  v_temperature numeric(4,2);
  v_weight numeric(5,2);
  v_minute_offset int;
BEGIN
  -- 1. 创建健康档案
  INSERT INTO health_records (
    id, user_id, name, relationship, gender, birth_date,
    height, weight, blood_type,
    medical_history, allergy_history, surgery_history, medication_history,
    is_default, created_at, updated_at
  ) VALUES (
    v_record_id, v_user_id, '李强', '本人', '男', '1988-06-15',
    174.00, 75.80, 'A',
    '无重大既往病史', '无已知过敏史', '无手术史', '无长期用药',
    true,
    '2025-01-01T00:00:00+08:00',
    '2025-01-01T00:00:00+08:00'
  );

  -- 2. 生成每周体征数据：2025-01-01 至 2026-02-20
  v_current_date := '2025-01-01T08:00:00+08:00'::timestamptz;

  WHILE v_current_date <= '2026-02-20T23:59:59+08:00'::timestamptz LOOP
    -- 季节性正弦波 (年周期)
    v_seasonal := sin(2 * pi() * v_week_index / 52.0);

    -- 心率：基线72，夏季略高，±4
    v_heart_rate := 72 + round(v_seasonal * 2 + (random() - 0.5) * 6)::int;
    v_heart_rate := GREATEST(64, LEAST(82, v_heart_rate));

    -- 收缩压：基线120，±5
    v_systolic := 120 + round(v_seasonal * 2 + (random() - 0.5) * 8)::int;
    v_systolic := GREATEST(112, LEAST(130, v_systolic));

    -- 舒张压：基线77，±3
    v_diastolic := 77 + round(v_seasonal * 1.5 + (random() - 0.5) * 5)::int;
    v_diastolic := GREATEST(70, LEAST(84, v_diastolic));

    -- 空腹血糖：基线5.02，±0.3
    v_blood_sugar := round((5.02 + (random() - 0.5) * 0.6)::numeric, 2);
    v_blood_sugar := GREATEST(4.40, LEAST(5.60, v_blood_sugar));

    -- 体温：基线36.50，±0.2
    v_temperature := round((36.50 + (random() - 0.5) * 0.4)::numeric, 2);
    v_temperature := GREATEST(36.20, LEAST(36.80, v_temperature));

    -- 体重：基线75.8，冬季略高夏季略低，±0.5
    v_weight := round((75.80 - v_seasonal * 0.3 + (random() - 0.5) * 0.8)::numeric, 1);
    v_weight := GREATEST(74.80, LEAST(76.80, v_weight));

    -- 随机测量时间偏移（7:30-9:00 AM）
    v_minute_offset := floor(random() * 90)::int;

    INSERT INTO vital_signs (
      id, record_id, heart_rate, systolic_pressure, diastolic_pressure,
      blood_sugar, temperature, weight, recorded_at, notes
    ) VALUES (
      gen_random_uuid(),
      v_record_id,
      v_heart_rate,
      v_systolic,
      v_diastolic,
      v_blood_sugar,
      v_temperature,
      v_weight,
      v_current_date + (v_minute_offset * interval '1 minute') - interval '30 minutes',
      ''
    );

    v_current_date := v_current_date + interval '7 days';
    v_week_index := v_week_index + 1;
  END LOOP;

  -- 3. 关联医疗报告到健康档案
  UPDATE medical_reports
  SET record_id = v_record_id
  WHERE user_id = v_user_id;

  RAISE NOTICE '健康档案 ID: %, 生成体征记录: % 条', v_record_id, v_week_index;
END $$;
