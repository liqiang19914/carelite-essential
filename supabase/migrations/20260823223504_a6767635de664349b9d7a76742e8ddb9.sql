CREATE OR REPLACE FUNCTION public._diet_map_probe2(a jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_qmap jsonb := '{"q1":{"0":0,"1":1,"2":2}}'::jsonb;
  v_ans text := '1';
  v_val_ok boolean := false;
  v_matched int := 0;
  v_num numeric;
  v_metric jsonb := '{"skeletalMuscleKg":"30","weight":"60"}'::jsonb;
  v_order_arr text[];
BEGIN
  IF (v_qmap -> 'q1') ? v_ans THEN
    v_matched := v_matched + 1;
  END IF;

  IF (v_metric ->> 'weight') ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
    v_num := (v_metric ->> 'weight')::numeric;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM jsonb_array_elements_text('["borderline","high"]'::jsonb) x WHERE x = 'high'
  ) INTO v_val_ok;

  v_order_arr := ARRAY(
    SELECT jsonb_array_elements_text('["S","A","C","N","D","G"]'::jsonb)
  );

  RETURN jsonb_build_object(
    'matched', v_matched,
    'num', v_num,
    'ok', v_val_ok,
    'order', to_jsonb(v_order_arr)
  );
END;
$function$;