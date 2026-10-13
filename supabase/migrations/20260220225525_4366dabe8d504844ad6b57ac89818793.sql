
-- 修复：将体征数据和体检报告迁移到用户已有的健康档案
DO $$
DECLARE
  v_wrong_record_id uuid := '66b93c69-2acd-4a96-ab87-e06d2a262ff3';
  v_correct_record_id uuid := '70a1e80f-f8db-4d58-afcc-33920f89dbc6';
  v_vital_count int;
  v_report_count int;
BEGIN
  -- 1. 迁移体征数据到正确的健康档案
  UPDATE vital_signs
  SET record_id = v_correct_record_id
  WHERE record_id = v_wrong_record_id;
  GET DIAGNOSTICS v_vital_count = ROW_COUNT;

  -- 2. 迁移体检报告到正确的健康档案
  UPDATE medical_reports
  SET record_id = v_correct_record_id
  WHERE record_id = v_wrong_record_id;
  GET DIAGNOSTICS v_report_count = ROW_COUNT;

  -- 3. 删除多余的健康档案
  DELETE FROM health_records WHERE id = v_wrong_record_id;

  RAISE NOTICE '迁移完成：% 条体征记录、% 份体检报告已关联到正确档案', v_vital_count, v_report_count;
END $$;
