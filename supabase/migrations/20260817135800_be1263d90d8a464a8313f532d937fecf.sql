-- ============================================================
-- 角色权限表 RLS + 角色管理 RPC
-- ============================================================

-- 1) 角色相关表启用 RLS（阻止 anon/authenticated 直连，访问走 SECURITY DEFINER RPC）
ALTER TABLE public.enterprise_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.enterprise_role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.permission_definitions ENABLE ROW LEVEL SECURITY;

-- 权限定义是静态目录，authenticated 可读（角色编辑器按树展示）
DROP POLICY IF EXISTS "authenticated can read permission definitions" ON public.permission_definitions;
CREATE POLICY "authenticated can read permission definitions"
  ON public.permission_definitions FOR SELECT
  TO authenticated
  USING (true);

-- 2) 角色列表（当前登录人所属企业的角色 + 权限码 + 成员数）
CREATE OR REPLACE FUNCTION public.list_enterprise_roles()
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_ent uuid;
  v_result json;
BEGIN
  SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = auth.uid();
  IF v_ent IS NULL THEN
    RETURN '[]'::json;
  END IF;

  SELECT COALESCE(json_agg(x ORDER BY x.sort), '[]'::json)
  INTO v_result
  FROM (
    SELECT
      r.id,
      r.code,
      r.name,
      r.description,
      r.is_system,
      r.is_owner_role,
      COALESCE(
        (SELECT json_agg(rp.permission_code ORDER BY rp.permission_code)
         FROM public.enterprise_role_permissions rp WHERE rp.role_id = r.id),
        '[]'::json
      ) AS permissions,
      (SELECT count(*)::int FROM public.profiles p WHERE p.enterprise_role_id = r.id) AS member_count,
      CASE r.code
        WHEN 'super_admin' THEN 0 WHEN 'admin' THEN 1 WHEN 'operator' THEN 2
        WHEN 'health_manager' THEN 3 WHEN 'finance' THEN 4 ELSE 99 END AS sort
    FROM public.enterprise_roles r
    WHERE r.enterprise_id = v_ent
  ) x;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_roles() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_enterprise_roles() TO authenticated;

-- 3) 保存角色（新建/编辑；仅超级管理员；owner 角色不可改）
CREATE OR REPLACE FUNCTION public.save_enterprise_role(
  p_id uuid,
  p_name text,
  p_description text,
  p_permission_codes text[]
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ent uuid;
  v_role_id uuid;
  v_existing record;
BEGIN
  IF v_uid IS NULL THEN
    RETURN json_build_object('error', '未登录');
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RETURN json_build_object('error', '仅超级管理员可管理角色');
  END IF;
  SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = v_uid;
  IF v_ent IS NULL THEN
    RETURN json_build_object('error', '无企业归属');
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.enterprise_roles (enterprise_id, code, name, description, is_system, is_owner_role)
    VALUES (v_ent, 'custom_' || substr(md5(random()::text), 1, 8), btrim(p_name), COALESCE(p_description, ''), false, false)
    RETURNING id INTO v_role_id;
  ELSE
    SELECT * INTO v_existing FROM public.enterprise_roles WHERE id = p_id AND enterprise_id = v_ent;
    IF NOT FOUND THEN
      RETURN json_build_object('error', '角色不存在');
    END IF;
    IF v_existing.is_owner_role THEN
      RETURN json_build_object('error', '超级管理员角色不可修改');
    END IF;
    v_role_id := p_id;
    UPDATE public.enterprise_roles
       SET name = btrim(COALESCE(NULLIF(btrim(COALESCE(p_name, '')), ''), name)),
           description = COALESCE(p_description, description),
           updated_at = now()
     WHERE id = v_role_id;
  END IF;

  DELETE FROM public.enterprise_role_permissions WHERE role_id = v_role_id;
  IF p_permission_codes IS NOT NULL THEN
    INSERT INTO public.enterprise_role_permissions (role_id, permission_code)
    SELECT v_role_id, unnest(p_permission_codes);
  END IF;

  RETURN json_build_object('success', true, 'role_id', v_role_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.save_enterprise_role(uuid, text, text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_enterprise_role(uuid, text, text, text[]) TO authenticated;

-- 4) 删除角色（仅超级管理员；系统角色与 owner 角色不可删）
CREATE OR REPLACE FUNCTION public.delete_enterprise_role(p_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ent uuid;
  v_existing record;
BEGIN
  IF v_uid IS NULL THEN
    RETURN json_build_object('error', '未登录');
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RETURN json_build_object('error', '仅超级管理员可管理角色');
  END IF;
  SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = v_uid;

  SELECT * INTO v_existing FROM public.enterprise_roles WHERE id = p_id AND enterprise_id = v_ent;
  IF NOT FOUND THEN
    RETURN json_build_object('error', '角色不存在');
  END IF;
  IF v_existing.is_system OR v_existing.is_owner_role THEN
    RETURN json_build_object('error', '内置角色不可删除');
  END IF;

  UPDATE public.profiles SET enterprise_role_id = NULL WHERE enterprise_role_id = p_id;
  DELETE FROM public.enterprise_roles WHERE id = p_id;
  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_enterprise_role(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_enterprise_role(uuid) TO authenticated;

-- 5) 给成员分配角色（企业管理员或超管；目标成员须同企业）
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
  ) THEN
    RETURN json_build_object('error', '成员不在本企业');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.enterprise_roles WHERE id = p_role_id AND enterprise_id = v_ent
  ) THEN
    RETURN json_build_object('error', '角色不存在');
  END IF;

  UPDATE public.profiles SET enterprise_role_id = p_role_id WHERE id = p_member_id;
  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.set_member_role(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_member_role(uuid, uuid) TO authenticated;