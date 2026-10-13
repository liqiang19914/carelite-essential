-- ============================================================
-- 企业实体化：enterprises 表 + profiles/managers 企业归属
-- ============================================================

-- 1) enterprises 表（owner 外键内联，无需 DO 块）
CREATE TABLE IF NOT EXISTS public.enterprises (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 100),
  owner_profile_id uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
  logo_url text NOT NULL DEFAULT '',
  contact_phone text NOT NULL DEFAULT '',
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 2) profiles/managers 企业归属列
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS enterprise_id uuid REFERENCES public.enterprises(id) ON DELETE RESTRICT;

ALTER TABLE public.managers
  ADD COLUMN IF NOT EXISTS enterprise_id uuid REFERENCES public.enterprises(id) ON DELETE RESTRICT;

-- 3) 索引
CREATE UNIQUE INDEX IF NOT EXISTS enterprises_owner_unique
  ON public.enterprises (owner_profile_id)
  WHERE owner_profile_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS profiles_enterprise_idx
  ON public.profiles (enterprise_id, is_disabled, id);

CREATE INDEX IF NOT EXISTS managers_enterprise_idx
  ON public.managers (enterprise_id, id);

-- 4) 企业归属 helper 函数
CREATE OR REPLACE FUNCTION public.get_profile_enterprise_id(p_uid uuid)
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT enterprise_id FROM public.profiles WHERE id = p_uid;
$function$;

CREATE OR REPLACE FUNCTION public.get_my_enterprise_id()
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT enterprise_id FROM public.profiles WHERE id = auth.uid();
$function$;

CREATE OR REPLACE FUNCTION public.is_enterprise_owner(p_uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.enterprises e
    WHERE e.owner_profile_id = p_uid
  );
$function$;

CREATE OR REPLACE FUNCTION public.is_enterprise_member(p_enterprise_id uuid, p_uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = p_uid AND p.enterprise_id = p_enterprise_id
  );
$function$;

REVOKE ALL ON FUNCTION public.get_profile_enterprise_id(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_profile_enterprise_id(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_my_enterprise_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_enterprise_id() TO authenticated;
REVOKE ALL ON FUNCTION public.is_enterprise_owner(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_enterprise_owner(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.is_enterprise_member(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_enterprise_member(uuid, uuid) TO authenticated;

-- 5) 改造 get_enterprise_root_manager_id：优先 enterprise_id -> owner，无企业时回退旧逻辑
CREATE OR REPLACE FUNCTION public.get_enterprise_root_manager_id(uid uuid)
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT COALESCE(
    e.owner_profile_id,
    CASE
      WHEN p.role = 'manager' AND p.parent_manager_id IS NULL THEN p.id
      WHEN p.role = 'manager' AND p.parent_manager_id IS NOT NULL THEN p.parent_manager_id
      ELSE NULL
    END
  )
  FROM public.profiles p
  LEFT JOIN public.enterprises e ON e.id = p.enterprise_id
  WHERE p.id = uid;
$function$;

REVOKE ALL ON FUNCTION public.get_enterprise_root_manager_id(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_enterprise_root_manager_id(uuid) TO authenticated;

-- 6) 防提权触发器：把 enterprise_id 也纳入保护字段
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

-- 7) enterprises 表 RLS
ALTER TABLE public.enterprises ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Members can view own enterprise" ON public.enterprises;
CREATE POLICY "Members can view own enterprise"
  ON public.enterprises FOR SELECT
  USING (public.is_enterprise_member(id, auth.uid()));

DROP POLICY IF EXISTS "Admins can view all enterprises" ON public.enterprises;
CREATE POLICY "Admins can view all enterprises"
  ON public.enterprises FOR SELECT
  USING (public.is_admin(auth.uid()));

-- 8) 回填：建一个企业，全部现有商户归入，第一位商户=owner/超管。
--    期间临时停用坐席限额触发器（结构迁移，非真实新增坐席）
ALTER TABLE public.profiles DISABLE TRIGGER trg_enforce_membership_seat_limit;

DO $function$
DECLARE
  v_owner uuid;
  v_ent uuid;
  v_name text;
BEGIN
  IF EXISTS (SELECT 1 FROM public.profiles WHERE role = 'manager' AND enterprise_id IS NULL) THEN
    SELECT id INTO v_owner
      FROM public.profiles
      WHERE role = 'manager'
      ORDER BY created_at NULLS LAST, id
      LIMIT 1;

    IF v_owner IS NULL THEN
      RETURN;
    END IF;

    SELECT left(COALESCE(
      NULLIF(trim(m.business_name), ''),
      NULLIF(trim(p.nickname), ''),
      '默认企业'
    ), 100) INTO v_name
    FROM public.profiles p
    LEFT JOIN public.managers m ON m.id = p.id
    WHERE p.id = v_owner;

    INSERT INTO public.enterprises (name, owner_profile_id, created_by)
    VALUES (v_name, v_owner, v_owner)
    RETURNING id INTO v_ent;

    UPDATE public.profiles
       SET enterprise_id = v_ent
     WHERE role = 'manager' AND enterprise_id IS NULL;

    UPDATE public.managers m
       SET enterprise_id = v_ent
     WHERE m.enterprise_id IS NULL
       AND EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = m.id AND p.role = 'manager');

    -- 其余 manager 全部归到 owner 名下（扁平结构，原 boss 变员工）
    UPDATE public.profiles
       SET parent_manager_id = v_owner
     WHERE role = 'manager'
       AND id <> v_owner
       AND parent_manager_id IS DISTINCT FROM v_owner;
  END IF;
END;
$function$;

ALTER TABLE public.profiles ENABLE TRIGGER trg_enforce_membership_seat_limit;