-- ============================================================
-- Feature 426：update_enterprise_employment / set_primary_employment /
-- list_my_employments / get_current_enterprise_access
-- 镜像规则：profiles 旧列只反映主就业（primary employment），
-- 改主就业/改主就业行字段时同步镜像，改副就业字段不动镜像（防双源漂移）。
-- ============================================================

-- 改就业行字段（角色/上级/子角色/权限/状态）；仅当该行是主就业时同步 profiles 镜像。
-- 状态切到 active/pending 时由 trg_enforce_employment_seat_limit 做坐席校验。
CREATE OR REPLACE FUNCTION public.update_enterprise_employment(
  p_employment_id uuid,
  p_enterprise_role_id uuid DEFAULT NULL,
  p_supervisor_auth_user_id uuid DEFAULT NULL,
  p_sub_role text DEFAULT NULL,
  p_permissions jsonb DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_operator_auth_user_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row public.enterprise_employments;
  v_effective_sub_role text;
  v_effective_permissions jsonb;
BEGIN
  SELECT * INTO v_row FROM public.enterprise_employments WHERE id = p_employment_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '就业记录不存在' USING ERRCODE = 'P0001';
  END IF;

  IF p_status IS NOT NULL AND p_status NOT IN ('active', 'disabled', 'left', 'pending') THEN
    RAISE EXCEPTION '无效的就业状态' USING ERRCODE = 'P0001';
  END IF;

  -- 角色必须属于该就业所在企业
  IF p_enterprise_role_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.enterprise_roles
       WHERE id = p_enterprise_role_id AND enterprise_id = v_row.enterprise_id
     ) THEN
    RAISE EXCEPTION '所选角色不存在或不属于本企业' USING ERRCODE = 'P0001';
  END IF;

  v_effective_sub_role := COALESCE(NULLIF(btrim(p_sub_role), ''), v_row.sub_role);
  v_effective_permissions := COALESCE(p_permissions, v_row.permissions);

  UPDATE public.enterprise_employments
     SET enterprise_role_id = COALESCE(p_enterprise_role_id, v_row.enterprise_role_id),
         supervisor_auth_user_id = CASE
           WHEN p_supervisor_auth_user_id IS NOT NULL THEN p_supervisor_auth_user_id
           ELSE v_row.supervisor_auth_user_id
         END,
         sub_role = v_effective_sub_role,
         permissions = v_effective_permissions,
         status = COALESCE(p_status, v_row.status),
         updated_at = now()
   WHERE id = p_employment_id;

  -- 主就业行字段变化 → 同步 profiles 镜像
  IF v_row.is_primary THEN
    UPDATE public.profiles
       SET role = CASE WHEN role = 'user' THEN 'manager' ELSE role END,
           parent_manager_id = COALESCE(p_supervisor_auth_user_id, v_row.supervisor_auth_user_id),
           enterprise_id = v_row.enterprise_id,
           enterprise_role_id = COALESCE(p_enterprise_role_id, v_row.enterprise_role_id),
           sub_role = v_effective_sub_role,
           permissions = v_effective_permissions,
           updated_at = now()
     WHERE id = v_row.auth_user_id;
  END IF;

  IF p_operator_auth_user_id IS NOT NULL THEN
    INSERT INTO public.operation_logs (user_id, action, detail, module, metadata)
    VALUES (
      p_operator_auth_user_id,
      '编辑员工',
      format('更新了员工就业（%s），企业：%s', v_row.auth_user_id, v_row.enterprise_id),
      '企业中心',
      jsonb_build_object(
        'employment_id', p_employment_id,
        'enterprise_role_id', COALESCE(p_enterprise_role_id, v_row.enterprise_role_id),
        'sub_role', v_effective_sub_role,
        'status', COALESCE(p_status, v_row.status)
      )
    );
  END IF;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.update_enterprise_employment(uuid, uuid, uuid, text, jsonb, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_enterprise_employment(uuid, uuid, uuid, text, jsonb, text, uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_enterprise_employment(uuid, uuid, uuid, text, jsonb, text, uuid) TO service_role;

-- 把指定就业设为该账号的主就业，并同步 profiles 镜像（旧列只反映主就业）
CREATE OR REPLACE FUNCTION public.set_primary_employment(
  p_auth_user_id uuid,
  p_employment_id uuid,
  p_operator_auth_user_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row public.enterprise_employments;
BEGIN
  SELECT * INTO v_row
  FROM public.enterprise_employments
  WHERE id = p_employment_id AND auth_user_id = p_auth_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '就业记录不存在' USING ERRCODE = 'P0001';
  END IF;
  IF v_row.status = 'left' THEN
    RAISE EXCEPTION '已离职的就业不能设为主就业' USING ERRCODE = 'P0001';
  END IF;

  -- 取消其它主就业标记（partial unique 保证一人至多一条主就业）
  UPDATE public.enterprise_employments
     SET is_primary = false, updated_at = now()
   WHERE auth_user_id = p_auth_user_id AND id <> p_employment_id;

  UPDATE public.enterprise_employments
     SET is_primary = true, updated_at = now()
   WHERE id = p_employment_id;

  -- 同步 profiles 镜像
  UPDATE public.profiles
     SET role = CASE WHEN role = 'user' THEN 'manager' ELSE role END,
         parent_manager_id = v_row.supervisor_auth_user_id,
         enterprise_id = v_row.enterprise_id,
         enterprise_role_id = v_row.enterprise_role_id,
         sub_role = v_row.sub_role,
         permissions = v_row.permissions,
         primary_employment_id = p_employment_id,
         updated_at = now()
   WHERE id = p_auth_user_id;

  IF p_operator_auth_user_id IS NOT NULL THEN
    INSERT INTO public.operation_logs (user_id, action, detail, module, metadata)
    VALUES (
      p_operator_auth_user_id,
      '切换主就业',
      format('将账号 %s 的主就业切换到企业 %s', p_auth_user_id, v_row.enterprise_id),
      '企业中心',
      jsonb_build_object('employment_id', p_employment_id, 'enterprise_id', v_row.enterprise_id)
    );
  END IF;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.set_primary_employment(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_primary_employment(uuid, uuid, uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_primary_employment(uuid, uuid, uuid) TO service_role;

-- 当前登录人查自己的就业列表（含企业名/角色名）
CREATE OR REPLACE FUNCTION public.list_my_employments()
RETURNS TABLE(
  employment_id uuid,
  enterprise_id uuid,
  enterprise_name text,
  enterprise_role_id uuid,
  role_name text,
  supervisor_auth_user_id uuid,
  sub_role text,
  permissions jsonb,
  status text,
  is_primary boolean,
  created_at timestamptz
)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    ee.id,
    ee.enterprise_id,
    e.name,
    ee.enterprise_role_id,
    r.name,
    ee.supervisor_auth_user_id,
    ee.sub_role,
    ee.permissions,
    ee.status,
    ee.is_primary,
    ee.created_at
  FROM public.enterprise_employments ee
  JOIN public.enterprises e ON e.id = ee.enterprise_id
  LEFT JOIN public.enterprise_roles r ON r.id = ee.enterprise_role_id
  WHERE ee.auth_user_id = auth.uid()
  ORDER BY ee.is_primary DESC, ee.created_at DESC;
$function$;

REVOKE ALL ON FUNCTION public.list_my_employments() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_my_employments() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_my_employments() TO authenticated;

-- 就业上下文解析：优先指定就业（须属于本人），否则主就业，否则任一有效就业
CREATE OR REPLACE FUNCTION public.get_current_enterprise_access(p_employment_id uuid DEFAULT NULL)
RETURNS TABLE(
  employment_id uuid,
  enterprise_id uuid,
  enterprise_name text,
  enterprise_role_id uuid,
  role_name text,
  supervisor_auth_user_id uuid,
  sub_role text,
  permissions jsonb,
  status text,
  is_primary boolean,
  root_manager_id uuid
)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    ee.id,
    ee.enterprise_id,
    e.name,
    ee.enterprise_role_id,
    r.name,
    ee.supervisor_auth_user_id,
    ee.sub_role,
    ee.permissions,
    ee.status,
    ee.is_primary,
    e.owner_profile_id
  FROM public.enterprise_employments ee
  JOIN public.enterprises e ON e.id = ee.enterprise_id
  LEFT JOIN public.enterprise_roles r ON r.id = ee.enterprise_role_id
  WHERE ee.auth_user_id = auth.uid()
    AND (
      (p_employment_id IS NOT NULL AND ee.id = p_employment_id)
      OR (p_employment_id IS NULL AND ee.is_primary AND ee.status IN ('active','disabled','pending'))
      OR (p_employment_id IS NULL AND NOT EXISTS (
            SELECT 1 FROM public.enterprise_employments p
            WHERE p.auth_user_id = auth.uid() AND p.is_primary AND p.status IN ('active','disabled','pending')
          ))
    )
  ORDER BY ee.is_primary DESC, ee.created_at DESC
  LIMIT 1;
$function$;

REVOKE ALL ON FUNCTION public.get_current_enterprise_access(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_current_enterprise_access(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_current_enterprise_access(uuid) TO authenticated;