-- 修复：跨企业入职时主就业唯一索引冲突（enterprise_employments_primary_unique）
-- 背景：A 企业超级管理员（已有 is_primary=true 就业）被 B 企业按手机号入职时，
-- 原函数 INSERT 直接写 is_primary=true，立即撞全局部分唯一索引
-- （auth_user_id WHERE is_primary AND status IN active/disabled/pending），
-- 导致"员工入职写入失败：duplicate key value"，跨企业兼职无法入职。
-- 多商户隔离以 enterprise_employments 为权威：一人可有多条就业，但仅一条主就业
-- （决定登录默认落点与 profiles 镜像）。跨企业入职应作为非主就业加入，不抢占原主身份。
CREATE OR REPLACE FUNCTION public.create_enterprise_employment(
  p_auth_user_id uuid,
  p_enterprise_id uuid,
  p_enterprise_role_id uuid DEFAULT NULL::uuid,
  p_supervisor_auth_user_id uuid DEFAULT NULL::uuid,
  p_sub_role text DEFAULT 'health_manager'::text,
  p_permissions jsonb DEFAULT '{}'::jsonb,
  p_make_primary boolean DEFAULT true,
  p_operator_auth_user_id uuid DEFAULT NULL::uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_existing_id uuid;
  v_employment_id uuid;
  v_effective_sub_role text := COALESCE(NULLIF(btrim(p_sub_role), ''), 'health_manager');
  v_permissions jsonb := COALESCE(p_permissions, '{}'::jsonb);
  v_operator uuid := COALESCE(p_operator_auth_user_id, auth.uid());
  v_make_primary boolean := COALESCE(p_make_primary, true);
  v_has_primary boolean;
  v_enterprise_name text;
  v_auth_phone text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.enterprises WHERE id = p_enterprise_id) THEN
    RAISE EXCEPTION '企业不存在' USING ERRCODE = 'P0001';
  END IF;

  IF p_enterprise_role_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.enterprise_roles
       WHERE id = p_enterprise_role_id AND enterprise_id = p_enterprise_id
     ) THEN
    RAISE EXCEPTION '所选角色不存在或不属于本企业' USING ERRCODE = 'P0001';
  END IF;

  -- 幂等：同企业已在职 → 返回现有行
  SELECT id INTO v_existing_id
  FROM public.enterprise_employments
  WHERE auth_user_id = p_auth_user_id
    AND enterprise_id = p_enterprise_id
    AND status IN ('active', 'disabled', 'pending')
  LIMIT 1;
  IF v_existing_id IS NOT NULL THEN
    RETURN v_existing_id;
  END IF;

  -- 坐席早退校验
  DECLARE
    v_seat_error text := public.check_employment_seat_limit(p_enterprise_id, p_auth_user_id);
  BEGIN
    IF v_seat_error IS NOT NULL THEN
      RAISE EXCEPTION '%', v_seat_error USING ERRCODE = 'P0001';
    END IF;
  END;

  -- 是否在其他企业已有主就业（跨企业兼职判断；同企业已有行已在上方幂等返回）
  SELECT EXISTS (
    SELECT 1 FROM public.enterprise_employments
    WHERE auth_user_id = p_auth_user_id
      AND is_primary
      AND status IN ('active', 'disabled', 'pending')
  ) INTO v_has_primary;

  -- 跨企业入职不抢占原主就业：新行一律先以非主就业插入（避免部分唯一索引当场冲突），
  -- 仅当调用方要求主就业且该人尚无任何主就业时，插入后再提升。
  IF v_make_primary AND NOT v_has_primary THEN
    INSERT INTO public.enterprise_employments (
      auth_user_id, enterprise_id, enterprise_role_id, supervisor_auth_user_id,
      sub_role, permissions, status, is_primary
    ) VALUES (
      p_auth_user_id, p_enterprise_id, p_enterprise_role_id, p_supervisor_auth_user_id,
      v_effective_sub_role, v_permissions, 'active', true
    )
    RETURNING id INTO v_employment_id;
  ELSE
    INSERT INTO public.enterprise_employments (
      auth_user_id, enterprise_id, enterprise_role_id, supervisor_auth_user_id,
      sub_role, permissions, status, is_primary
    ) VALUES (
      p_auth_user_id, p_enterprise_id, p_enterprise_role_id, p_supervisor_auth_user_id,
      v_effective_sub_role, v_permissions, 'active', false
    )
    RETURNING id INTO v_employment_id;
    v_make_primary := false;
  END IF;

  -- 主就业 → 镜像 profiles 旧列
  -- 【关键】不再镜像 role！role 是原始身份，由注册入口决定，不应被就业覆盖。
  IF v_make_primary THEN
    UPDATE public.profiles
       SET parent_manager_id = p_supervisor_auth_user_id,
           enterprise_id = p_enterprise_id,
           enterprise_role_id = p_enterprise_role_id,
           sub_role = v_effective_sub_role,
           permissions = v_permissions,
           primary_employment_id = v_employment_id,
           updated_at = now()
     WHERE id = p_auth_user_id;
  END IF;

  IF v_operator IS NOT NULL THEN
    SELECT name INTO v_enterprise_name FROM public.enterprises WHERE id = p_enterprise_id;
    SELECT phone INTO v_auth_phone FROM public.profiles WHERE id = p_auth_user_id;
    INSERT INTO public.operation_logs (user_id, action, detail, module, metadata)
    VALUES (
      v_operator,
      '员工入职',
      format('新增员工（%s，%s）入职「%s」，角色：%s%s',
        COALESCE((SELECT nickname FROM public.profiles WHERE id = p_auth_user_id), ''),
        COALESCE(v_auth_phone, ''),
        COALESCE(v_enterprise_name, ''),
        v_effective_sub_role,
        CASE WHEN v_make_primary THEN '' ELSE '（跨企业兼职，主就业保留在原企业）' END
      ),
      '企业中心',
      jsonb_build_object(
        'employment_id', v_employment_id,
        'auth_user_id', p_auth_user_id,
        'enterprise_id', p_enterprise_id,
        'enterprise_role_id', p_enterprise_role_id,
        'sub_role', v_effective_sub_role,
        'is_primary', v_make_primary,
        'mode', 'create_enterprise_employment'
      )
    );
  END IF;

  RETURN v_employment_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_enterprise_employment(uuid, uuid, uuid, uuid, text, jsonb, boolean, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_enterprise_employment(uuid, uuid, uuid, uuid, text, jsonb, boolean, uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_enterprise_employment(uuid, uuid, uuid, uuid, text, jsonb, boolean, uuid) TO service_role;
