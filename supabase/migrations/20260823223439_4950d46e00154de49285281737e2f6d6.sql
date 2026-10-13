CREATE OR REPLACE FUNCTION public._diet_map_probe(a jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_t text;
  v_scores jsonb := '{}'::jsonb;
BEGIN
  FOREACH v_t IN ARRAY ARRAY['S','D','G','N','C','A'] LOOP
    v_scores := v_scores || jsonb_build_object(v_t, 0);
  END LOOP;
  RETURN v_scores;
END;
$function$;