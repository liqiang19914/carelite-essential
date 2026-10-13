-- ============================================================
-- 企业角色与权限：角色表 + 权限定义表 + 角色权限关联表
-- ============================================================

-- 1) 企业角色表
CREATE TABLE IF NOT EXISTS public.enterprise_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  enterprise_id uuid NOT NULL REFERENCES public.enterprises(id) ON DELETE CASCADE,
  code text NOT NULL,
  name text NOT NULL,
  description text NOT NULL DEFAULT '',
  is_system boolean NOT NULL DEFAULT false,
  is_owner_role boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT enterprise_roles_enterprise_code_key UNIQUE (enterprise_id, code)
);

-- 2) 权限定义表（全局，含菜单节点树 + 动作权限）
CREATE TABLE IF NOT EXISTS public.permission_definitions (
  code text PRIMARY KEY,
  name text NOT NULL,
  node_level smallint NOT NULL CHECK (node_level BETWEEN 1 AND 3),
  parent_code text REFERENCES public.permission_definitions(code) ON DELETE CASCADE,
  permission_kind text NOT NULL CHECK (permission_kind IN ('menu', 'action')),
  sort_order integer NOT NULL DEFAULT 0
);

-- 3) 角色-权限关联表
CREATE TABLE IF NOT EXISTS public.enterprise_role_permissions (
  role_id uuid NOT NULL REFERENCES public.enterprise_roles(id) ON DELETE CASCADE,
  permission_code text NOT NULL REFERENCES public.permission_definitions(code) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_code)
);

-- 4) profiles 企业角色列
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS enterprise_role_id uuid REFERENCES public.enterprise_roles(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS profiles_enterprise_role_idx
  ON public.profiles (enterprise_role_id)
  WHERE enterprise_role_id IS NOT NULL;

-- 5) 防提权触发器：把 enterprise_role_id 也纳入保护字段
CREATE OR REPLACE FUNCTION public.prevent_profile_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $function$
BEGIN
  IF (NEW.role IS DISTINCT FROM OLD.role)
     OR (NEW.parent_manager_id IS DISTINCT FROM OLD.parent_manager_id)
     OR (NEW.sub_role IS DISTINCT FROM OLD.sub_role)
     OR (NEW.permissions IS DISTINCT FROM OLD.permissions)
     OR (NEW.enterprise_id IS DISTINCT FROM OLD.enterprise_id)
     OR (NEW.enterprise_role_id IS DISTINCT FROM OLD.enterprise_role_id)
     OR (NEW.is_disabled IS DISTINCT FROM OLD.is_disabled)
     OR (NEW.disabled_at IS DISTINCT FROM OLD.disabled_at)
     OR (NEW.disabled_reason IS DISTINCT FROM OLD.disabled_reason)
  THEN
    IF auth.role() IS NOT NULL
       AND auth.role() <> 'service_role'
       AND NOT is_admin(auth.uid())
    THEN
      RAISE EXCEPTION '无权修改角色、上级归属、权限或禁用状态字段' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

-- 6) 权限校验函数：企业主（owner）恒真，否则看角色是否挂该权限
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
      FROM public.profiles p
      JOIN public.enterprise_role_permissions rp ON rp.role_id = p.enterprise_role_id
      WHERE p.id = p_uid AND rp.permission_code = p_permission_code
    );
$function$;

REVOKE ALL ON FUNCTION public.has_enterprise_permission(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.has_enterprise_permission(text, uuid) TO authenticated;

-- 7) 当前登录人的权限码集合（企业主返回全部权限码）
CREATE OR REPLACE FUNCTION public.get_my_permissions()
RETURNS text[]
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM public.enterprises e WHERE e.owner_profile_id = auth.uid())
    THEN (SELECT COALESCE(array_agg(code ORDER BY code), ARRAY[]::text[]) FROM public.permission_definitions)
    ELSE COALESCE(
      (SELECT array_agg(rp.permission_code ORDER BY rp.permission_code)
       FROM public.profiles p
       JOIN public.enterprise_role_permissions rp ON rp.role_id = p.enterprise_role_id
       WHERE p.id = auth.uid()),
      ARRAY[]::text[]
    )
  END;
$function$;

REVOKE ALL ON FUNCTION public.get_my_permissions() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_permissions() TO authenticated;