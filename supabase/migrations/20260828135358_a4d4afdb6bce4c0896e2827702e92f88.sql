-- 体重突变提醒：商户级设置 + 测量记录跨成员转移
CREATE TABLE IF NOT EXISTS public.merchant_weight_anomaly_settings (
  root_manager_id uuid PRIMARY KEY REFERENCES public.managers(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT true,
  absolute_threshold_kg numeric(5,2) NOT NULL DEFAULT 8
    CHECK (absolute_threshold_kg > 0 AND absolute_threshold_kg <= 50),
  percentage_threshold numeric(4,3) NOT NULL DEFAULT 0.15
    CHECK (percentage_threshold > 0 AND percentage_threshold < 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

COMMENT ON TABLE public.merchant_weight_anomaly_settings IS
  '体重突变提醒设置：root_manager_id 按企业根商户一行；两个阈值同时达到才提醒';
COMMENT ON COLUMN public.merchant_weight_anomaly_settings.absolute_threshold_kg IS
  '与最近 30 天记录的差的绝对值阈值（公斤）';
COMMENT ON COLUMN public.merchant_weight_anomaly_settings.percentage_threshold IS
  '与最近 30 天记录的差的相对阈值（0.15 即 15%）';

ALTER TABLE public.merchant_weight_anomaly_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.merchant_weight_anomaly_settings FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_weight_anomaly_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_weight_anomaly_settings TO service_role;

ALTER TABLE public.body_compositions
  ADD COLUMN IF NOT EXISTS metrics_profile_record_id uuid
  REFERENCES public.health_records(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.body_compositions.metrics_profile_record_id IS
  '体成分指标按哪个档案参数（身高/性别/年龄）计算；转移成员后保持原档案';

CREATE OR REPLACE FUNCTION public.get_merchant_weight_anomaly_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_row public.merchant_weight_anomaly_settings%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.is_active_enterprise_content_member(v_uid) THEN
    RAISE EXCEPTION '所属企业当前不可配置，请联系企业负责人或平台处理' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);

  SELECT * INTO v_row
  FROM public.merchant_weight_anomaly_settings
  WHERE root_manager_id = v_root;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('enabled', true, 'absolute_threshold_kg', 8, 'percentage_threshold', 0.15);
  END IF;

  RETURN jsonb_build_object(
    'enabled', v_row.enabled,
    'absolute_threshold_kg', v_row.absolute_threshold_kg,
    'percentage_threshold', v_row.percentage_threshold
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.save_merchant_weight_anomaly_settings(
  p_enabled boolean,
  p_absolute_threshold_kg numeric,
  p_percentage_threshold numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_abs numeric := COALESCE(p_absolute_threshold_kg, 8);
  v_pct numeric := COALESCE(p_percentage_threshold, 0.15);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.is_active_enterprise_content_member(v_uid) THEN
    RAISE EXCEPTION '所属企业当前不可保存，请联系企业负责人或平台处理' USING ERRCODE = '42501';
  END IF;
  IF v_abs < 1 OR v_abs > 50 THEN
    RAISE EXCEPTION '体重差阈值需在 1 到 50 公斤之间' USING ERRCODE = '22023';
  END IF;
  IF v_pct <= 0 OR v_pct >= 1 THEN
    RAISE EXCEPTION '体重差百分比需大于 0 且小于 1，例如 0.15 表示百分之十五' USING ERRCODE = '22023';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);

  INSERT INTO public.merchant_weight_anomaly_settings
    (root_manager_id, enabled, absolute_threshold_kg, percentage_threshold, updated_by, updated_at)
  VALUES (v_root, COALESCE(p_enabled, true), v_abs, v_pct, v_uid, now())
  ON CONFLICT (root_manager_id) DO UPDATE
    SET enabled = EXCLUDED.enabled,
        absolute_threshold_kg = EXCLUDED.absolute_threshold_kg,
        percentage_threshold = EXCLUDED.percentage_threshold,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object('success', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_public_merchant_weight_anomaly_settings(p_root_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row public.merchant_weight_anomaly_settings%ROWTYPE;
BEGIN
  IF p_root_manager_id IS NULL
     OR NOT public.is_public_enterprise_content_root(p_root_manager_id) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_weight_anomaly_settings
  WHERE root_manager_id = p_root_manager_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('enabled', true, 'absolute_threshold_kg', 8, 'percentage_threshold', 0.15);
  END IF;

  RETURN jsonb_build_object(
    'enabled', v_row.enabled,
    'absolute_threshold_kg', v_row.absolute_threshold_kg,
    'percentage_threshold', v_row.percentage_threshold
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.transfer_body_composition_record(
  p_composition_id uuid,
  p_target_record_id uuid
)
RETURNS public.body_compositions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.body_compositions%ROWTYPE;
  v_target_owner uuid;
  v_target_height numeric;
  v_new_fingerprint text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_row
  FROM public.body_compositions
  WHERE id = p_composition_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '没有找到这条测量记录' USING ERRCODE = '22023';
  END IF;

  IF NOT public.owns_health_record(v_uid, v_row.record_id) THEN
    RAISE EXCEPTION '无权转移这条记录' USING ERRCODE = '42501';
  END IF;

  SELECT user_id, height INTO v_target_owner, v_target_height
  FROM public.health_records
  WHERE id = p_target_record_id;

  IF v_target_owner IS NULL OR v_target_owner <> v_uid THEN
    RAISE EXCEPTION '无权使用该健康档案' USING ERRCODE = '42501';
  END IF;

  IF p_target_record_id = v_row.record_id THEN
    RAISE EXCEPTION '这条记录已经在该成员名下' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.body_compositions
    WHERE id <> p_composition_id
      AND record_id = p_target_record_id
      AND measured_at = v_row.measured_at
      AND provider_key = v_row.provider_key
  ) THEN
    RAISE EXCEPTION '目标成员在同一时间已有一条同品牌测量记录，无法转移' USING ERRCODE = '23505';
  END IF;

  IF v_row.idempotency_key IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.body_compositions
    WHERE id <> p_composition_id
      AND record_id = p_target_record_id
      AND idempotency_key = v_row.idempotency_key
  ) THEN
    RAISE EXCEPTION '目标成员名下已有同一次测量的记录，无法转移' USING ERRCODE = '23505';
  END IF;

  IF v_row.provider_measurement_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.body_compositions
    WHERE id <> p_composition_id
      AND provider_measurement_id = v_row.provider_measurement_id
  ) THEN
    RAISE EXCEPTION '这条设备测量已存在于其他成员名下，无法转移' USING ERRCODE = '23505';
  END IF;

  v_new_fingerprint := encode(
    extensions.digest(
      COALESCE(p_target_record_id::text, '') || '|' ||
      COALESCE(to_char(v_row.measured_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS'), '') || '|' ||
      COALESCE(v_row.provider_key, '') || '|' ||
      COALESCE(v_row.weight::text, '') || '|' ||
      COALESCE(v_row.body_fat_percent::text, ''),
      'sha256'
    ),
    'hex'
  );

  IF EXISTS (
    SELECT 1 FROM public.body_compositions
    WHERE id <> p_composition_id AND fingerprint = v_new_fingerprint
  ) THEN
    RAISE EXCEPTION '目标成员名下已有同一次测量的记录，无法转移' USING ERRCODE = '23505';
  END IF;

  UPDATE public.body_compositions
  SET record_id = p_target_record_id,
      bmi = CASE
        WHEN v_target_height >= 50 AND v_target_height <= 250
          THEN round((v_row.weight / ((v_target_height / 100.0) * (v_target_height / 100.0)))::numeric, 1)
        ELSE NULL
      END,
      metrics_meta = metrics_meta - 'bmi',
      fingerprint = v_new_fingerprint,
      metrics_profile_record_id = COALESCE(v_row.metrics_profile_record_id, v_row.record_id)
  WHERE id = p_composition_id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_merchant_weight_anomaly_settings() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_merchant_weight_anomaly_settings() TO authenticated;
REVOKE ALL ON FUNCTION public.save_merchant_weight_anomaly_settings(boolean, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_merchant_weight_anomaly_settings(boolean, numeric, numeric) TO authenticated;
REVOKE ALL ON FUNCTION public.get_public_merchant_weight_anomaly_settings(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_merchant_weight_anomaly_settings(uuid) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.transfer_body_composition_record(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.transfer_body_composition_record(uuid, uuid) TO authenticated;