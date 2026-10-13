CREATE OR REPLACE FUNCTION public._diet_map_probe4(a jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_muscle_kg numeric;
  v_weight_kg numeric;
  v_metric jsonb := '{}'::jsonb;
BEGIN
  v_muscle_kg := 30;
  v_weight_kg := 60;
  v_metric := v_metric || jsonb_build_object(
    'skeletalMusclePercent',
    round((v_muscle_kg / v_weight_kg * 100)::numeric, 1)::text
  );
  RETURN v_metric;
END;
$function$;

COMMENT ON FUNCTION public._diet_map_probe4(jsonb) IS 'probe4 注释测试';

GRANT EXECUTE ON FUNCTION public._diet_map_probe4(jsonb) TO authenticated;