CREATE OR REPLACE FUNCTION public.transfer_medical_report_record(p_report_id uuid, p_target_record_id uuid)
 RETURNS medical_reports
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_report medical_reports%ROWTYPE;
  v_target_owner UUID;
BEGIN
  SELECT user_id INTO v_target_owner
  FROM health_records
  WHERE id = p_target_record_id;

  IF v_target_owner IS NULL OR v_target_owner <> auth.uid() THEN
    RAISE EXCEPTION '无权使用该健康档案';
  END IF;

  PERFORM 1 FROM medical_reports
  WHERE id = p_report_id AND user_id = auth.uid()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '无权转移该报告';
  END IF;

  UPDATE medical_reports
  SET record_id = p_target_record_id, updated_at = now()
  WHERE id = p_report_id
  RETURNING * INTO v_report;

  UPDATE report_interpretations
  SET record_id = p_target_record_id
  WHERE report_id = p_report_id;

  -- A comparison is inherently a same-person before/after trend; once one side's
  -- report moves to a different family member the cached comparison no longer
  -- describes a coherent trend, so drop it instead of leaving stale content.
  -- compare-medical-reports will regenerate on next request if still needed.
  DELETE FROM report_comparisons
  WHERE report_older_id = p_report_id OR report_newer_id = p_report_id;

  RETURN v_report;
END;
$function$;