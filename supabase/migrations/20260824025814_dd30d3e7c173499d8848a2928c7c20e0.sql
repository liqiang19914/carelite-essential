-- feature 289 补充：企业角色分配需要穿过防提权触发器
-- 触发器只放行「受控 SECURITY DEFINER 函数内显式申请」的会话（set_config 会话级、函数结束自动失效），
-- 直接 UPDATE profiles 的越权路径仍被拦截。

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
    IF current_setting('app.allow_profile_privilege_change', true) IS DISTINCT FROM 'true'
       AND auth.role() IS NOT NULL
       AND auth.role() <> 'service_role'
       AND NOT is_admin(auth.uid())
    THEN
      RAISE EXCEPTION '无权修改角色、上级归属、权限或禁用状态字段' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

-- set_member_role：函数内申请受控放行后再改 enterprise_role_id
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

  PERFORM set_config('app.allow_profile_privilege_change', 'true', true);
  UPDATE public.profiles SET enterprise_role_id = p_role_id WHERE id = p_member_id;
  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.set_member_role(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_member_role(uuid, uuid) TO authenticated;

-- delete_enterprise_role：同样申请受控放行
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

  PERFORM set_config('app.allow_profile_privilege_change', 'true', true);
  UPDATE public.profiles SET enterprise_role_id = NULL WHERE enterprise_role_id = p_id;
  DELETE FROM public.enterprise_roles WHERE id = p_id;
  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_enterprise_role(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_enterprise_role(uuid) TO authenticated;