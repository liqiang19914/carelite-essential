CREATE OR REPLACE FUNCTION public._diet_map_probe6(a jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_order_arr text[];
BEGIN
  v_order_arr := ARRAY(
    SELECT jsonb_array_elements_text(COALESCE(a -> 'dimensionOrder', '["S","A","C","N","D","G"]'::jsonb))
  );
  RETURN to_jsonb(v_order_arr);
END;
$function$;