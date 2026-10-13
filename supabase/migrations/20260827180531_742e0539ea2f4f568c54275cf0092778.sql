-- 客户详情「基本信息」保存：把性别/出生日期写回户主档案（无户主档案返回业务码，不擅自建档案）
CREATE OR REPLACE FUNCTION public.manager_update_client_owner_profile(
  p_relation_id uuid,
  p_gender text DEFAULT NULL,
  p_birth_date date DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_client_id uuid;
  v_owner_record_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF p_relation_id IS NULL THEN
    RAISE EXCEPTION '缺少客户标识' USING ERRCODE = '22023';
  END IF;

  -- 该关系必须归属当前商户（或本企业任一员工），否则无权操作
  SELECT cr.client_id INTO v_client_id
  FROM public.client_relations cr
  WHERE cr.id = p_relation_id
    AND cr.manager_id IN (SELECT s.manager_id FROM public.oem_scope_manager_ids() s)
  LIMIT 1;

  IF v_client_id IS NULL THEN
    RAISE EXCEPTION '无权操作该客户' USING ERRCODE = '42501';
  END IF;

  -- 户主档案：默认优先、最早建档、稳定排序（与 BMI 口径一致）
  SELECT hr.id INTO v_owner_record_id
  FROM public.health_records hr
  WHERE hr.user_id = v_client_id
  ORDER BY hr.is_default DESC, hr.created_at ASC, hr.id ASC
  LIMIT 1;

  IF v_owner_record_id IS NULL THEN
    RETURN 'no_owner_record';
  END IF;

  UPDATE public.health_records hr
  SET gender = p_gender,
      birth_date = p_birth_date,
      updated_at = now()
  WHERE hr.id = v_owner_record_id;

  RETURN 'updated';
END;
$function$;

REVOKE ALL ON FUNCTION public.manager_update_client_owner_profile(uuid, text, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.manager_update_client_owner_profile(uuid, text, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.manager_update_client_owner_profile(uuid, text, date) TO authenticated;