-- 修复：profiles.sub_role 为 NOT NULL，离职清镜像时置空串而非 NULL
CREATE OR REPLACE FUNCTION public.leave_enterprise_employment(
  p_auth_user_id uuid,
  p_enterprise_id uuid,
  p_operator_auth_user_id uuid DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row public.enterprise_employments;
  v_next_id uuid;
  v_client_count integer;
  v_enterprise_name text;
BEGIN
  IF p_auth_user_id IS NULL OR p_enterprise_id IS NULL THEN
    RAISE EXCEPTION '参数缺失，无法解除就业' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.enterprises
    WHERE id = p_enterprise_id AND owner_profile_id = p_auth_user_id
  ) THEN
    RAISE EXCEPTION '企业主不能解除本企业的就业关系' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.managers m
    WHERE m.id = p_auth_user_id AND m.is_system_default
  ) THEN
    RAISE EXCEPTION '系统预置健康管理师不支持解除就业' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_row
  FROM public.enterprise_employments
  WHERE auth_user_id = p_auth_user_id
    AND enterprise_id = p_enterprise_id
    AND status IN ('active', 'disabled', 'pending')
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    IF EXISTS (
      SELECT 1 FROM public.enterprise_employments
      WHERE auth_user_id = p_auth_user_id
        AND enterprise_id = p_enterprise_id
        AND status = 'left'
    ) THEN
      RETURN json_build_object('success', true, 'already_left', true);
    END IF;
    RAISE EXCEPTION '该员工不在本企业，无法解除就业' USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*) INTO v_client_count
  FROM public.client_relations
  WHERE manager_id = p_auth_user_id AND status = 'active';
  IF v_client_count > 0 THEN
    RETURN json_build_object(
      'blocked', true,
      'client_count', v_client_count,
      'message', format('该员工名下还有 %s 位客户未交接，请先在员工详情「客户」页把客户转让给企业主或其他员工，再解除就业', v_client_count)
    );
  END IF;

  UPDATE public.enterprise_employments
     SET status = 'left', is_primary = false, updated_at = now()
   WHERE id = v_row.id;

  SELECT ee.id INTO v_next_id
  FROM public.enterprise_employments ee
  WHERE ee.auth_user_id = p_auth_user_id
    AND ee.status IN ('active', 'disabled', 'pending')
  ORDER BY ee.created_at ASC
  LIMIT 1;

  IF v_next_id IS NOT NULL THEN
    IF v_row.is_primary THEN
      PERFORM public.set_primary_employment(p_auth_user_id, v_next_id, p_operator_auth_user_id);
    END IF;
  ELSE
    UPDATE public.profiles
       SET role = CASE
             WHEN role = 'admin' THEN role
             WHEN EXISTS (SELECT 1 FROM public.enterprises e WHERE e.owner_profile_id = p_auth_user_id) THEN role
             ELSE 'user'::public.user_role
           END,
           parent_manager_id = NULL,
           enterprise_id = NULL,
           enterprise_role_id = NULL,
           sub_role = '',
           permissions = '{}'::jsonb,
           primary_employment_id = NULL,
           is_disabled = false,
           disabled_at = NULL,
           disabled_reason = NULL,
           updated_at = now()
     WHERE id = p_auth_user_id;
  END IF;

  IF p_operator_auth_user_id IS NOT NULL THEN
    SELECT name INTO v_enterprise_name FROM public.enterprises WHERE id = p_enterprise_id;
    INSERT INTO public.operation_logs (user_id, action, detail, module, metadata)
    VALUES (
      p_operator_auth_user_id,
      '解除企业就业',
      format('解除了员工（%s）在「%s」的就业关系',
        COALESCE((SELECT nickname FROM public.profiles WHERE id = p_auth_user_id), p_auth_user_id::text),
        COALESCE(v_enterprise_name, '')),
      '企业中心',
      jsonb_build_object(
        'employment_id', v_row.id,
        'auth_user_id', p_auth_user_id,
        'enterprise_id', p_enterprise_id,
        'promoted_employment_id', v_next_id,
        'remaining_valid', v_next_id IS NOT NULL
      )
    );
  END IF;

  RETURN json_build_object(
    'success', true,
    'employment_id', v_row.id,
    'promoted_employment_id', v_next_id,
    'remaining_valid', v_next_id IS NOT NULL
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.leave_enterprise_employment(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.leave_enterprise_employment(uuid, uuid, uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.leave_enterprise_employment(uuid, uuid, uuid) TO service_role;