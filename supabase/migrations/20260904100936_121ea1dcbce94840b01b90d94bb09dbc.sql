-- ============================================================
-- Feature 426：坐席校验辅助 + create_enterprise_employment
-- 就业表坐席口径：按企业数 active/pending 就业、COUNT(DISTINCT auth_user_id)、
-- 排除 is_system_default 预置健管师（与 enforce_membership_seat_limit 旧口径一致，
-- 旧触发器保留作为 profiles 直写路径的兜底，两边回填后口径一致不会双算）。
-- ============================================================

-- 辅助：返回 NULL=通过，否则返回中文错误文案（create 函数早退 + 触发器兜底共用）
CREATE OR REPLACE FUNCTION public.check_employment_seat_limit(
  p_enterprise_id uuid,
  p_exclude_auth_user_id uuid DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root_id uuid;
  v_root public.managers;
  v_plan public.membership_plans;
  v_effective_limit integer;
  v_current_count integer;
BEGIN
  SELECT e.owner_profile_id INTO v_root_id
  FROM public.enterprises e
  WHERE e.id = p_enterprise_id;

  IF v_root_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT m.* INTO v_root FROM public.managers m WHERE m.id = v_root_id;
  IF NOT FOUND OR v_root.membership_enforcement_mode = 'legacy_unlimited' THEN
    RETURN NULL;
  END IF;

  SELECT p.* INTO v_plan FROM public.membership_plans p WHERE p.code = v_root.membership_level;
  IF NOT FOUND OR NOT v_plan.hard_enforce_numeric_limits THEN
    RETURN NULL;
  END IF;

  v_effective_limit := COALESCE(v_root.seat_limit_override, v_plan.manager_seat_limit);

  SELECT COUNT(DISTINCT emp.auth_user_id) INTO v_current_count
  FROM public.enterprise_employments emp
  WHERE emp.enterprise_id = p_enterprise_id
    AND (p_exclude_auth_user_id IS NULL OR emp.auth_user_id <> p_exclude_auth_user_id)
    AND emp.status IN ('active', 'pending')
    AND NOT EXISTS (
      SELECT 1 FROM public.managers m WHERE m.id = emp.auth_user_id AND m.is_system_default
    );

  IF v_current_count + 1 > v_effective_limit THEN
    RETURN format('当前套餐健康管理师坐席已达上限（%s人），请联系平台升级套餐', v_effective_limit);
  END IF;

  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.check_employment_seat_limit(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.check_employment_seat_limit(uuid, uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_employment_seat_limit(uuid, uuid) TO service_role;

-- 就业表坐席触发器（INSERT 或 status 从非 active/pending → active/pending 时校验）
CREATE OR REPLACE FUNCTION public.enforce_employment_seat_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_was_active_seat boolean := false;
  v_error text;
BEGIN
  IF NEW.status NOT IN ('active', 'pending') THEN
    RETURN NEW;
  END IF;

  -- 系统预置健管师不占坐席（与旧触发器一致）
  IF EXISTS (SELECT 1 FROM public.managers m WHERE m.id = NEW.auth_user_id AND m.is_system_default) THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    v_was_active_seat := (OLD.status IN ('active', 'pending'));
    IF v_was_active_seat THEN
      RETURN NEW;
    END IF;
  END IF;

  -- 锁企业 owner 行防并发超卖（与旧触发器 FOR UPDATE 同思路）
  PERFORM 1 FROM public.enterprises e
    JOIN public.managers m ON m.id = e.owner_profile_id
   WHERE e.id = NEW.enterprise_id
   FOR UPDATE OF m;

  v_error := public.check_employment_seat_limit(NEW.enterprise_id, NEW.auth_user_id);
  IF v_error IS NOT NULL THEN
    RAISE EXCEPTION '%', v_error USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_enforce_employment_seat_limit ON public.enterprise_employments;
CREATE TRIGGER trg_enforce_employment_seat_limit
  BEFORE INSERT OR UPDATE OF status ON public.enterprise_employments
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_employment_seat_limit();

-- ============================================================
-- create_enterprise_employment：入职主入口（幂等）
-- 同企业已在职（active/disabled/pending）→ 返回现有行 id，不重复建；
-- 否则写就业行 + 镜像 profiles 旧列（role→manager、parent/enterprise/role/sub_role/permissions
-- + primary_employment_id）+ operation_logs。p_operator 供 EF 传调用者（service_role 调用时 auth.uid() 为 NULL）。
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_enterprise_employment(
  p_auth_user_id uuid,
  p_enterprise_id uuid,
  p_enterprise_role_id uuid DEFAULT NULL,
  p_supervisor_auth_user_id uuid DEFAULT NULL,
  p_sub_role text DEFAULT 'health_manager',
  p_permissions jsonb DEFAULT '{}'::jsonb,
  p_make_primary boolean DEFAULT true,
  p_operator_auth_user_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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

  -- 坐席早退校验（触发器兜底防并发）
  DECLARE
    v_seat_error text := public.check_employment_seat_limit(p_enterprise_id, p_auth_user_id);
  BEGIN
    IF v_seat_error IS NOT NULL THEN
      RAISE EXCEPTION '%', v_seat_error USING ERRCODE = 'P0001';
    END IF;
  END;

  INSERT INTO public.enterprise_employments (
    auth_user_id, enterprise_id, enterprise_role_id, supervisor_auth_user_id,
    sub_role, permissions, status, is_primary
  ) VALUES (
    p_auth_user_id, p_enterprise_id, p_enterprise_role_id, p_supervisor_auth_user_id,
    v_effective_sub_role, v_permissions, 'active', v_make_primary
  )
  RETURNING id INTO v_employment_id;

  -- 该账号还没有任何主就业时，把这条设为主（保证 primary 唯一索引 + 镜像锚点成立）
  SELECT EXISTS (
    SELECT 1 FROM public.enterprise_employments
    WHERE auth_user_id = p_auth_user_id AND is_primary AND id <> v_employment_id
  ) INTO v_has_primary;
  IF NOT v_has_primary THEN
    v_make_primary := true;
    UPDATE public.enterprise_employments
       SET is_primary = true, updated_at = now()
     WHERE id = v_employment_id;
  END IF;

  -- 主就业 → 镜像 profiles 旧列（旧列只反映主就业，防双源漂移）
  IF v_make_primary THEN
    UPDATE public.enterprise_employments
       SET is_primary = false, updated_at = now()
     WHERE auth_user_id = p_auth_user_id AND id <> v_employment_id;

    UPDATE public.profiles
       SET role = CASE WHEN role = 'user' THEN 'manager' ELSE role END,
           parent_manager_id = p_supervisor_auth_user_id,
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
      format('新增员工（%s，%s）入职「%s」，角色：%s',
        COALESCE((SELECT nickname FROM public.profiles WHERE id = p_auth_user_id), ''),
        COALESCE(v_auth_phone, ''),
        COALESCE(v_enterprise_name, ''),
        v_effective_sub_role),
      '企业中心',
      jsonb_build_object(
        'employment_id', v_employment_id,
        'auth_user_id', p_auth_user_id,
        'enterprise_id', p_enterprise_id,
        'enterprise_role_id', p_enterprise_role_id,
        'sub_role', v_effective_sub_role,
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