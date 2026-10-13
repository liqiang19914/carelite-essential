CREATE OR REPLACE FUNCTION public._diet_map_probe3(a jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_types text[] := ARRAY['S','D','G','N','C','A'];
  v_t text;
  v_key text;
  v_rule jsonb;
  v_rules jsonb := '[{"id":"a","dimension":"S","source":{"kind":"metric","field":"bmi"},"operator":"gt","value":24,"score":1}]'::jsonb;
  v_primary text[] := ARRAY['S'];
  v_secondary text[] := ARRAY[]::text[];
  v_sec_cand text[] := ARRAY['D','G'];
  v_best numeric;
  v_pick text;
  v_balanced boolean;
  v_secs numeric[];
  v_scores jsonb := '{"S":8,"D":5,"G":6,"N":4,"C":3,"A":2}'::jsonb;
  v_tbv jsonb := '{"male":34,"female":29}'::jsonb;
  v_gender text := 'male';
  v_tb numeric;
  v_metric jsonb := '{}'::jsonb;
  v_inputs jsonb := '{"gender":{"questionCode":"h_gender"},"age":{"questionCode":"h_age"}}'::jsonb;
BEGIN
  FOR v_rule IN SELECT value FROM jsonb_array_elements(v_rules) LOOP
    CONTINUE WHEN v_rule ->> 'dimension' <> 'S';
    v_tb := NULLIF(v_tbv ->> v_gender, '')::numeric;
  END LOOP;

  FOR v_key IN SELECT jsonb_object_keys(v_inputs) LOOP
    v_metric := v_metric || jsonb_build_object(v_key, v_key);
  END LOOP;

  FOREACH v_t IN ARRAY v_types LOOP
    CONTINUE WHEN v_t = ANY(v_primary);
  END LOOP;

  SELECT bool_and(COALESCE((v_scores ->> t)::numeric, 0) <= 4.5)
    INTO v_balanced
    FROM unnest(v_types) t;

  SELECT array_agg(DISTINCT x.v ORDER BY x.v DESC)
    INTO v_secs
    FROM (SELECT COALESCE((v_scores ->> t)::numeric, 0) AS v FROM unnest(v_types) t) x;

  LOOP
    v_best := -1;
    v_pick := NULL;
    FOREACH v_t IN ARRAY v_sec_cand LOOP
      CONTINUE WHEN v_t = ANY(v_secondary);
      IF COALESCE((v_scores ->> v_t)::numeric, 0) > v_best THEN
        v_best := COALESCE((v_scores ->> v_t)::numeric, 0);
        v_pick := v_t;
      END IF;
    END LOOP;
    EXIT WHEN v_pick IS NULL;
    v_secondary := v_secondary || v_pick;
    EXIT WHEN array_length(v_secondary, 1) >= 2;
  END LOOP;

  RETURN jsonb_build_object(
    'balanced', COALESCE(v_balanced, false),
    'secs', to_jsonb(v_secs),
    'secondary', to_jsonb(v_secondary),
    'tb', v_tb,
    'metric', v_metric
  );
END;
$function$;