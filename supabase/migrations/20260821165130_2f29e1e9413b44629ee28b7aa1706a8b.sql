DO $function$
DECLARE
  v_rec record;
  v_cnt integer := 0;
BEGIN
  FOR v_rec IN
    SELECT e.id AS enterprise_id, e.owner_profile_id, e.name
      FROM public.enterprises e
     WHERE e.owner_profile_id IS NOT NULL
  LOOP
    PERFORM public.provision_system_health_managers(v_rec.owner_profile_id, v_rec.enterprise_id, v_rec.name);
    v_cnt := v_cnt + 1;
  END LOOP;
  RAISE NOTICE 'backfilled % enterprises', v_cnt;
END;
$function$;