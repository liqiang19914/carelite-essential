-- Fix 1 (P1): prevent any authenticated caller (non-admin, non-service-role) from
-- escalating privilege by rewriting their own or another profile's role /
-- parent_manager_id / sub_role / permissions / is_disabled / disabled_at / disabled_reason.
-- Root cause: profiles_update_policy allows any manager to UPDATE any profile row,
-- and the new enterprise boss/employee RLS policies + canManageTargetManager() all
-- trust profiles.parent_manager_id as ground truth. This trigger makes those columns
-- writable only by service-role Edge Functions, real admins, or direct DB/migration
-- connections (auth.role() IS NULL) — closing the escalation path without touching
-- any other profile field (nickname, avatar, notes, invited_by, etc. remain freely editable).
CREATE OR REPLACE FUNCTION public.prevent_profile_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF (NEW.role IS DISTINCT FROM OLD.role)
     OR (NEW.parent_manager_id IS DISTINCT FROM OLD.parent_manager_id)
     OR (NEW.sub_role IS DISTINCT FROM OLD.sub_role)
     OR (NEW.permissions IS DISTINCT FROM OLD.permissions)
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
$$;

DROP TRIGGER IF EXISTS trg_prevent_profile_privilege_escalation ON public.profiles;
CREATE TRIGGER trg_prevent_profile_privilege_escalation
BEFORE UPDATE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.prevent_profile_privilege_escalation();

-- Fix 2 (P1): get_manager_clients had zero internal authorization check and was
-- granted to anon + authenticated, so any caller who knew/guessed a manager UUID
-- could read that manager's full client list (name + phone). Add an authorization
-- check (self / admin / enterprise-boss-or-admin-of-that-manager) and revoke anon/PUBLIC.
CREATE OR REPLACE FUNCTION public.get_manager_clients(p_manager_id uuid)
RETURNS TABLE(relation_id uuid, client_id uuid, status text, notes text, last_contact_at timestamptz, relation_created_at timestamptz, nickname text, phone text, avatar_url text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    cr.id AS relation_id,
    cr.client_id,
    cr.status::text,
    cr.notes,
    cr.last_contact_at,
    cr.created_at AS relation_created_at,
    p.nickname::text,
    p.phone::text,
    p.avatar_url
  FROM client_relations cr
  LEFT JOIN profiles p ON p.id = cr.client_id
  WHERE cr.manager_id = p_manager_id
    AND (
      auth.uid() = p_manager_id
      OR is_admin(auth.uid())
      OR is_enterprise_member_for_admin(p_manager_id, auth.uid())
    )
  ORDER BY cr.created_at DESC;
$function$;

REVOKE EXECUTE ON FUNCTION public.get_manager_clients(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_manager_clients(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_manager_clients(uuid) TO authenticated;

-- Fix 3 (P1): employee deletion checked client_relations count then separately called
-- auth.admin.deleteUser — a client could be assigned in between (TOCTOU), and since the
-- FK was ON DELETE CASCADE, the relation would be silently destroyed instead of blocking
-- the deletion. Switch to ON DELETE RESTRICT so Postgres itself atomically refuses to
-- delete a manager/employee auth user while any client_relations row still references them.
ALTER TABLE public.client_relations
  DROP CONSTRAINT client_relations_manager_id_fkey;

ALTER TABLE public.client_relations
  ADD CONSTRAINT client_relations_manager_id_fkey
  FOREIGN KEY (manager_id) REFERENCES auth.users(id) ON DELETE RESTRICT;
