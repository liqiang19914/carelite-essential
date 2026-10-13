-- ============================================================
-- 体成分测量数据主表（每日称重模块）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.body_compositions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  record_id uuid NOT NULL REFERENCES public.health_records(id) ON DELETE CASCADE,
  measured_at timestamptz NOT NULL,
  provider_key text NOT NULL DEFAULT 'yolanda_scale',
  origin text NOT NULL DEFAULT 'live' CHECK (origin IN ('live','cached','manual')),

  -- 截图确认的 16 项指标 + 健康评分
  weight numeric(6,2) CHECK (weight IS NULL OR (weight > 0 AND weight < 400)),
  heart_rate integer CHECK (heart_rate IS NULL OR (heart_rate > 20 AND heart_rate < 250)),
  heart_index numeric(4,2) CHECK (heart_index IS NULL OR (heart_index >= 0 AND heart_index < 20)),
  bmi numeric(5,2) CHECK (bmi IS NULL OR (bmi > 0 AND bmi < 100)),
  body_fat_percent numeric(5,2) CHECK (body_fat_percent IS NULL OR (body_fat_percent >= 0 AND body_fat_percent <= 80)),
  water_percent numeric(5,2) CHECK (water_percent IS NULL OR (water_percent >= 0 AND water_percent <= 100)),
  skeletal_muscle_percent numeric(5,2) CHECK (skeletal_muscle_percent IS NULL OR (skeletal_muscle_percent >= 0 AND skeletal_muscle_percent <= 100)),
  muscle_mass numeric(6,2) CHECK (muscle_mass IS NULL OR (muscle_mass >= 0 AND muscle_mass < 300)),
  bone_mass numeric(5,2) CHECK (bone_mass IS NULL OR (bone_mass >= 0 AND bone_mass < 50)),
  lbm numeric(6,2) CHECK (lbm IS NULL OR (lbm >= 0 AND lbm < 300)),
  protein_percent numeric(5,2) CHECK (protein_percent IS NULL OR (protein_percent >= 0 AND protein_percent <= 100)),
  subcutaneous_fat_percent numeric(5,2) CHECK (subcutaneous_fat_percent IS NULL OR (subcutaneous_fat_percent >= 0 AND subcutaneous_fat_percent <= 100)),
  visceral_fat_level numeric(4,1) CHECK (visceral_fat_level IS NULL OR (visceral_fat_level >= 0 AND visceral_fat_level <= 60)),
  body_age integer CHECK (body_age IS NULL OR (body_age > 0 AND body_age < 150)),
  body_shape text,
  bmr integer CHECK (bmr IS NULL OR (bmr > 0 AND bmr < 10000)),
  health_score numeric(4,1) CHECK (health_score IS NULL OR (health_score >= 0 AND health_score <= 100)),

  -- 插件可能额外返回的派生项
  body_fat_mass numeric(6,2),
  water_mass numeric(6,2),
  protein_mass numeric(6,2),
  mineral_salt numeric(6,2),
  standard_weight numeric(6,2),
  weight_control numeric(6,2),
  fat_control numeric(6,2),
  muscle_control numeric(6,2),
  obesity_percent numeric(6,2),
  best_visual_weight numeric(6,2),
  fatty_liver_risk text,

  -- 八电极分段（CS20H1 不回，列位预留）
  seg_muscle_rh numeric(5,2), seg_muscle_lh numeric(5,2), seg_muscle_rf numeric(5,2),
  seg_muscle_lf numeric(5,2), seg_muscle_trunk numeric(5,2),
  seg_fat_rh numeric(5,2), seg_fat_lh numeric(5,2), seg_fat_rf numeric(5,2),
  seg_fat_lf numeric(5,2), seg_fat_trunk numeric(5,2),

  -- 元数据
  metrics_meta jsonb,
  device_ref jsonb,
  missing_metrics jsonb,
  idempotency_key text,
  provider_measurement_id text,
  fingerprint text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS body_compositions_natural_key
  ON public.body_compositions (record_id, measured_at, provider_key);
CREATE UNIQUE INDEX IF NOT EXISTS body_compositions_provider_measurement_id
  ON public.body_compositions (provider_measurement_id)
  WHERE provider_measurement_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS body_compositions_fingerprint
  ON public.body_compositions (fingerprint)
  WHERE fingerprint IS NOT NULL;
CREATE INDEX IF NOT EXISTS body_compositions_record_measured
  ON public.body_compositions (record_id, measured_at DESC);

-- ============================================================
-- 服务端指纹：同一档案 + 同一时刻 + 同一体重/体脂 视为同一次测量
-- ============================================================
CREATE OR REPLACE FUNCTION public.body_compositions_set_fingerprint()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'extensions'
AS $$
BEGIN
  IF NEW.fingerprint IS NULL THEN
    NEW.fingerprint := encode(
      extensions.digest(
        COALESCE(NEW.record_id::text, '') || '|' ||
        COALESCE(to_char(NEW.measured_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS'), '') || '|' ||
        COALESCE(NEW.provider_key, '') || '|' ||
        COALESCE(NEW.weight::text, '') || '|' ||
        COALESCE(NEW.body_fat_percent::text, ''),
        'sha256'
      ),
      'hex'
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_body_compositions_fingerprint ON public.body_compositions;
CREATE TRIGGER trg_body_compositions_fingerprint
  BEFORE INSERT ON public.body_compositions
  FOR EACH ROW EXECUTE FUNCTION public.body_compositions_set_fingerprint();

-- ============================================================
-- 管理师可见性：绑定关系 active + 档案授权 active + 用户开启 share_vitals
-- ============================================================
CREATE OR REPLACE FUNCTION public.can_current_manager_view_body_composition(p_record_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.record_authorizations ra
    JOIN public.health_records hr ON hr.id = ra.record_id
    JOIN public.client_relations cr
      ON cr.manager_id = ra.manager_id AND cr.client_id = hr.user_id
    WHERE ra.record_id = p_record_id
      AND ra.manager_id = auth.uid()
      AND ra.is_active = true
      AND (ra.expires_at IS NULL OR ra.expires_at > now())
      AND cr.status = 'active'
      AND public.can_manager_view_client_category(hr.user_id, 'share_vitals')
  );
$$;

-- ============================================================
-- RLS
-- ============================================================
ALTER TABLE public.body_compositions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage own body compositions" ON public.body_compositions;
CREATE POLICY "Users manage own body compositions"
  ON public.body_compositions FOR ALL TO authenticated
  USING (public.owns_health_record(auth.uid(), record_id))
  WITH CHECK (public.owns_health_record(auth.uid(), record_id));

DROP POLICY IF EXISTS "Managers view authorized body compositions" ON public.body_compositions;
CREATE POLICY "Managers view authorized body compositions"
  ON public.body_compositions FOR SELECT TO authenticated
  USING (public.can_current_manager_view_body_composition(record_id));

DROP POLICY IF EXISTS "Admins view all body compositions" ON public.body_compositions;
CREATE POLICY "Admins view all body compositions"
  ON public.body_compositions FOR SELECT TO authenticated
  USING (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Service role writes body compositions" ON public.body_compositions;
CREATE POLICY "Service role writes body compositions"
  ON public.body_compositions FOR ALL TO service_role
  USING (true) WITH CHECK (true);

COMMENT ON TABLE public.body_compositions IS '体成分测量记录（体脂秤 BLE 测量 / 手动录入），按 record_id 归属家庭成员档案';
COMMENT ON COLUMN public.body_compositions.metrics_meta IS '插件返回的分段/范围/状态/建议文案，原样存储，不做二次判断';
COMMENT ON COLUMN public.body_compositions.missing_metrics IS '[{key, reason: age_restricted|not_detected}] 未测出项及原因';