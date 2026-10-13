CREATE OR REPLACE FUNCTION public.manager_weighing_overview()
RETURNS TABLE(today_count bigint, people_count bigint, total_count bigint, provider_counts jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid());
  v_today_start timestamptz :=
    (((pg_catalog.now() AT TIME ZONE 'Asia/Shanghai')::date)::timestamp AT TIME ZONE 'Asia/Shanghai');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
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
  -- 与列表、行级策略同一口径：我方商户章的数据 + 尚未确定归属的历史数据
  scoped AS (
    SELECT bc.record_id, bc.measured_at, bc.provider_key
    FROM public.body_compositions bc
    WHERE (bc.oem_manager_id IN (SELECT cm.manager_id FROM caller_members cm)
            AND public.record_vitals_shared(bc.record_id))
       OR (bc.oem_manager_id IS NULL
            AND bc.record_id IN (SELECT ar.rid FROM authorized_records ar))
  )
  SELECT
    (SELECT count(*) FROM scoped s WHERE s.measured_at >= v_today_start),
    (SELECT count(DISTINCT s.record_id) FROM scoped s),
    (SELECT count(*) FROM scoped s),
    coalesce((
      SELECT jsonb_object_agg(t.provider_key, t.cnt)
      FROM (SELECT s.provider_key, count(*) AS cnt FROM scoped s GROUP BY s.provider_key) t
    ), '{}'::jsonb);
END;
$function$;