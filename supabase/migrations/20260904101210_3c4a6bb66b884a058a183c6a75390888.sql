-- ============================================================
-- Feature 426：权限函数切就业口径（优先就业，查不到就业行回退旧列）
-- 保持签名与返回语义完全兼容；owner 判定继续走 enterprises.owner_profile_id。
-- 回退条件 = 该 uid 没有任何在职/禁用就业行（未回填干净的人行为不变）。
-- ============================================================

-- 企业成员：就业行（active/disabled/pending 都算成员，left 不算）或回退旧列
CREATE OR REPLACE FUNCTION public.is_enterprise_member(p_enterprise_id uuid, p_uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    EXISTS (
      SELECT 1 FROM public.enterprise_employments ee
      WHERE ee.auth_user_id = p_uid
        AND ee.enterprise_id = p_enterprise_id
        AND ee.status IN ('active', 'disabled', 'pending')
    )
    OR (
      NOT EXISTS (
        SELECT 1 FROM public.enterprise_employments
        WHERE auth_user_id = p_uid AND status IN ('active', 'disabled', 'pending')
      )
      AND EXISTS (
        SELECT 1 FROM public.profiles p
        WHERE p.id = p_uid AND p.enterprise_id = p_enterprise_id
      )
    );
$function$;

-- 企业管理员：就业口径（active 就业且无上级=owner，或 sub_role='admin'）；回退旧列
CREATE OR REPLACE FUNCTION public.is_enterprise_admin(uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    EXISTS (
      SELECT 1 FROM public.enterprise_employments ee
      WHERE ee.auth_user_id = uid
        AND ee.status = 'active'
        AND (ee.supervisor_auth_user_id IS NULL OR ee.sub_role = 'admin')
    )
    OR (
      NOT EXISTS (
        SELECT 1 FROM public.enterprise_employments
        WHERE auth_user_id = uid AND status IN ('active', 'disabled', 'pending')
      )
      AND EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = uid
          AND role = 'manager'
          AND COALESCE(is_disabled, false) = false
          AND (parent_manager_id IS NULL OR sub_role = 'admin')
      )
    );
$function$;

-- 权限码：owner 恒真；否则就业行角色权限；无就业行回退旧列
CREATE OR REPLACE FUNCTION public.has_enterprise_permission(p_permission_code text, p_uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    EXISTS (SELECT 1 FROM public.enterprises e WHERE e.owner_profile_id = p_uid)
    OR EXISTS (
      SELECT 1
      FROM public.enterprise_employments ee
      JOIN public.enterprise_role_permissions rp ON rp.role_id = ee.enterprise_role_id
      WHERE ee.auth_user_id = p_uid
        AND ee.status IN ('active', 'pending')
        AND rp.permission_code = p_permission_code
    )
    OR (
      NOT EXISTS (
        SELECT 1 FROM public.enterprise_employments
        WHERE auth_user_id = p_uid AND status IN ('active', 'disabled', 'pending')
      )
      AND EXISTS (
        SELECT 1
        FROM public.profiles p
        JOIN public.enterprise_role_permissions rp ON rp.role_id = p.enterprise_role_id
        WHERE p.id = p_uid AND rp.permission_code = p_permission_code
      )
    );
$function$;

-- 企业根：就业口径取主就业所在企业 owner；无就业行回退旧列（enterprise_id → owner，或 parent 链）
CREATE OR REPLACE FUNCTION public.get_enterprise_root_manager_id(uid uuid)
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT COALESCE(
    (
      SELECT e.owner_profile_id
      FROM public.enterprise_employments ee
      JOIN public.enterprises e ON e.id = ee.enterprise_id
      WHERE ee.auth_user_id = uid
        AND ee.status IN ('active', 'disabled', 'pending')
      ORDER BY ee.is_primary DESC, ee.created_at DESC
      LIMIT 1
    ),
    (
      SELECT COALESCE(
        e2.owner_profile_id,
        CASE
          WHEN p.role = 'manager' AND p.parent_manager_id IS NULL THEN p.id
          WHEN p.role = 'manager' AND p.parent_manager_id IS NOT NULL THEN p.parent_manager_id
          ELSE NULL
        END
      )
      FROM public.profiles p
      LEFT JOIN public.enterprises e2 ON e2.id = p.enterprise_id
      WHERE p.id = uid
    )
  );
$function$;

-- set_member_role：更新 profiles 旧列的同时同步就业表（就业表为权威，防双源漂移）
CREATE OR REPLACE FUNCTION public.set_member_role(p_member_id uuid, p_role_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ent uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN json_build_object('error', '未登录');
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_members', v_uid) THEN
    RETURN json_build_object('error', '无成员管理权限');
  END IF;
  SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = v_uid;
  IF v_ent IS NULL THEN
    RETURN json_build_object('error', '无企业归属');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = p_member_id AND enterprise_id = v_ent
  ) AND NOT EXISTS (
    SELECT 1 FROM public.enterprise_employments
    WHERE auth_user_id = p_member_id AND enterprise_id = v_ent AND status IN ('active', 'pending')
  ) THEN
    RETURN json_build_object('error', '成员不在本企业');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.enterprise_roles WHERE id = p_role_id AND enterprise_id = v_ent
  ) THEN
    RETURN json_build_object('error', '角色不存在');
  END IF;

  PERFORM set_config('app.allow_profile_privilege_change', 'true', true);
  UPDATE public.profiles SET enterprise_role_id = p_role_id WHERE id = p_member_id;

  -- 同步就业表：同企业在职/待入职就业行一起换角色
  UPDATE public.enterprise_employments
     SET enterprise_role_id = p_role_id, updated_at = now()
   WHERE auth_user_id = p_member_id
     AND enterprise_id = v_ent
     AND status IN ('active', 'pending');

  RETURN json_build_object('success', true);
END;
$function$;

-- 回填异常清单表（无法定归属的 manager 记录，供 428 或人工处理）
CREATE TABLE IF NOT EXISTS public.enterprise_employment_migration_exceptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL,
  reason text NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.enterprise_employment_migration_exceptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.enterprise_employment_migration_exceptions FROM anon, authenticated;