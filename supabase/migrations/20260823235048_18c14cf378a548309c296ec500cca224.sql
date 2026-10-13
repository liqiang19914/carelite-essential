-- 最小复现：验证 FOREACH + jsonb || 合并的实际行为
CREATE OR REPLACE FUNCTION public._dm_merge_test()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_code text;
  v_report jsonb := '{"types":{"S":{"a":1},"A":{"a":1},"G":{"a":1}}}'::jsonb;
BEGIN
  FOREACH v_code IN ARRAY ARRAY['S','A','G'] LOOP
    v_report := v_report || jsonb_build_object('types', jsonb_build_object(v_code, jsonb_build_object('x', 'y')));
  END LOOP;
  RETURN v_report;
END;
$function$;