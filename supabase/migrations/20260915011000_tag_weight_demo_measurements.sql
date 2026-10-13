-- The weight demo's 60 imported measurements predate the demo metadata flag.
-- Tag only measurements owned by its 20 synthetic +852000000xx customers.
DO $$
DECLARE
  v_root uuid := '9d20bc6b-cbd4-4153-84e5-01e5b58f041f';
  v_clients integer;
  v_measurements integer;
  v_updated integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.managers WHERE id=v_root AND is_example=true) THEN
    RAISE EXCEPTION 'weight demo manager is not marked as example';
  END IF;

  SELECT count(DISTINCT cr.client_id),count(bc.id)
    INTO v_clients,v_measurements
  FROM public.client_relations cr
  JOIN public.profiles p ON p.id=cr.client_id
  JOIN auth.users u ON u.id=cr.client_id
  JOIN public.health_records hr ON hr.user_id=cr.client_id
  JOIN public.body_compositions bc ON bc.record_id=hr.id
  WHERE cr.root_manager_id=v_root
    AND p.phone LIKE '+852000000__'
    AND bc.provider_key='imported';

  IF v_clients<>20 OR v_measurements<>60 THEN
    RAISE EXCEPTION 'weight demo provenance changed: % clients, % measurements',v_clients,v_measurements;
  END IF;

  UPDATE public.body_compositions bc
    SET metrics_meta=coalesce(bc.metrics_meta,'{}'::jsonb)
      || '{"demo":true,"source":"weight_demo_import"}'::jsonb
  FROM public.health_records hr
  JOIN public.client_relations cr ON cr.client_id=hr.user_id
  JOIN public.profiles p ON p.id=cr.client_id
  WHERE bc.record_id=hr.id
    AND cr.root_manager_id=v_root
    AND p.phone LIKE '+852000000__'
    AND bc.provider_key='imported'
    AND bc.metrics_meta->>'demo' IS DISTINCT FROM 'true';
  GET DIAGNOSTICS v_updated=ROW_COUNT;

  IF v_updated<>60 OR (public.get_public_readonly_demo('weight')->>'weighing_count')::integer<>60 THEN
    RAISE EXCEPTION 'weight demo check failed: tagged % measurements',v_updated;
  END IF;
END;
$$;
