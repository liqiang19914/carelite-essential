-- 修正返回类型与表实际列型一致（heart_rate/body_age/bmr 为 integer）
DROP FUNCTION IF EXISTS public.manager_record_compositions(uuid, integer, integer);

CREATE OR REPLACE FUNCTION public.manager_record_compositions(
  p_record_id uuid,
  p_limit integer DEFAULT 30,
  p_offset integer DEFAULT 0
)
RETURNS TABLE(
  id uuid,
  record_id uuid,
  measured_at timestamptz,
  provider_key text,
  origin text,
  weight numeric,
  heart_rate integer,
  heart_index numeric,
  bmi numeric,
  body_fat_percent numeric,
  water_percent numeric,
  skeletal_muscle_percent numeric,
  muscle_percent numeric,
  muscle_mass numeric,
  bone_mass numeric,
  lbm numeric,
  protein_percent numeric,
  subcutaneous_fat_percent numeric,
  visceral_fat_level numeric,
  body_age integer,
  body_shape text,
  bmr integer,
  muscle_storage_score numeric,
  health_score numeric,
  metrics_meta jsonb,
  missing_metrics jsonb,
  device_ref jsonb,
  notes text,
  oem_manager_id uuid,
  total_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 100);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF p_record_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH caller_members AS (
    SELECT s.manager_id FROM public.oem_scope_manager_ids() s
  ),
  authorized_records AS (
    SELECT ra.record_id AS rid
    FROM public.record_authorizations ra
    JOIN caller_members cm ON cm.manager_id = ra.manager_id
    JOIN public.health_records hr ON hr.id = ra.record_id
    JOIN public.client_relations cr
      ON cr.manager_id = ra.manager_id AND cr.client_id = hr.user_id
    WHERE ra.is_active = true
      AND (ra.expires_at IS NULL OR ra.expires_at > pg_catalog.now())
      AND cr.status = 'active'
      AND public.can_manager_view_client_category(hr.user_id, 'share_vitals')
    GROUP BY ra.record_id
  ),
  visible AS (
    SELECT bc.*
    FROM public.body_compositions bc
    WHERE bc.record_id = p_record_id
      AND (
        (bc.oem_manager_id IN (SELECT cm.manager_id FROM caller_members cm)
          AND public.record_vitals_shared(bc.record_id))
        OR (bc.oem_manager_id IS NULL
          AND bc.record_id IN (SELECT ar.rid FROM authorized_records ar))
      )
  ),
  counted AS (
    SELECT v.*, count(*) OVER () AS total_rows
    FROM visible v
  )
  SELECT c.id, c.record_id, c.measured_at, c.provider_key, c.origin,
         c.weight, c.heart_rate, c.heart_index, c.bmi,
         c.body_fat_percent, c.water_percent, c.skeletal_muscle_percent,
         c.muscle_percent, c.muscle_mass, c.bone_mass, c.lbm,
         c.protein_percent, c.subcutaneous_fat_percent, c.visceral_fat_level,
         c.body_age, c.body_shape, c.bmr, c.muscle_storage_score,
         c.health_score, c.metrics_meta, c.missing_metrics,
         c.device_ref, c.notes, c.oem_manager_id, c.total_rows
  FROM counted c
  ORDER BY c.measured_at DESC, c.id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.manager_record_compositions(uuid, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.manager_record_compositions(uuid, integer, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.manager_record_compositions(uuid, integer, integer) TO authenticated;