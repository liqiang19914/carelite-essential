-- get_manager_clients:重建以增加 privacy_settings 返回列 + 按 show_phone 阀门 mask phone。
-- 返回类型变了(增列)→ 必须先 DROP 再 CREATE(CREATE OR REPLACE 不允许改列)。
-- 其他行为(SECURITY DEFINER / STABLE / search_path / 授权判定)完全保持。
DROP FUNCTION IF EXISTS public.get_manager_clients(uuid);

CREATE OR REPLACE FUNCTION public.get_manager_clients(p_manager_id uuid)
RETURNS TABLE(
  relation_id uuid,
  client_id uuid,
  status text,
  notes text,
  last_contact_at timestamp with time zone,
  relation_created_at timestamp with time zone,
  nickname text,
  phone text,
  avatar_url text,
  privacy_settings jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
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
    CASE
      WHEN public.can_manager_view_client_category(cr.client_id, 'show_phone')
        THEN p.phone::text
      ELSE NULL
    END AS phone,
    p.avatar_url,
    COALESCE(p.privacy_settings, '{}'::jsonb) AS privacy_settings
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

REVOKE ALL ON FUNCTION public.get_manager_clients(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_manager_clients(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_manager_clients(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_manager_clients(uuid) TO service_role;

-- get_enterprise_clients_with_owner:同上重建。
-- 客户 phone 走 show_phone 阀门 mask;owner_manager_phone(管理师之间的联系方式)不动。
DROP FUNCTION IF EXISTS public.get_enterprise_clients_with_owner(integer, integer, text, uuid);

CREATE OR REPLACE FUNCTION public.get_enterprise_clients_with_owner(
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0,
  p_search text DEFAULT NULL::text,
  p_owner_manager_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(
  relation_id uuid,
  client_id uuid,
  status text,
  notes text,
  last_contact_at timestamp with time zone,
  relation_created_at timestamp with time zone,
  nickname text,
  phone text,
  avatar_url text,
  privacy_settings jsonb,
  owner_manager_id uuid,
  owner_manager_nickname text,
  owner_manager_phone text,
  owner_sub_role text,
  owner_is_disabled boolean,
  total_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_is_admin boolean;
  v_root uuid;
  v_limit int;
  v_offset int;
  v_search text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  SELECT public.is_enterprise_admin(v_uid) INTO v_is_admin;
  IF NOT v_is_admin THEN
    RAISE EXCEPTION '仅企业管理员可访问' USING ERRCODE = '42501';
  END IF;

  SELECT public.get_enterprise_root_manager_id(v_uid) INTO v_root;
  IF v_root IS NULL THEN
    RETURN;
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);
  v_search := NULLIF(TRIM(COALESCE(p_search, '')), '');

  RETURN QUERY
  WITH members AS (
    SELECT v_root AS mid
    UNION
    SELECT p.id
    FROM public.profiles p
    WHERE p.parent_manager_id = v_root AND p.role = 'manager'
  ),
  scoped AS (
    SELECT cr.*
    FROM public.client_relations cr
    WHERE cr.manager_id IN (SELECT mid FROM members)
      AND (p_owner_manager_id IS NULL OR cr.manager_id = p_owner_manager_id)
      AND (
        v_search IS NULL
        OR EXISTS (
          SELECT 1 FROM public.profiles cp
          WHERE cp.id = cr.client_id
            AND (cp.nickname ILIKE '%' || v_search || '%'
                 OR cp.phone ILIKE '%' || v_search || '%')
        )
      )
  )
  SELECT
    s.id AS relation_id,
    s.client_id,
    s.status::text,
    s.notes,
    s.last_contact_at,
    s.created_at AS relation_created_at,
    cp.nickname::text,
    CASE
      WHEN public.can_manager_view_client_category(s.client_id, 'show_phone')
        THEN cp.phone::text
      ELSE NULL
    END AS phone,
    cp.avatar_url,
    COALESCE(cp.privacy_settings, '{}'::jsonb) AS privacy_settings,
    s.manager_id AS owner_manager_id,
    op.nickname::text AS owner_manager_nickname,
    op.phone::text AS owner_manager_phone,
    COALESCE(op.sub_role, '')::text AS owner_sub_role,
    COALESCE(op.is_disabled, false) AS owner_is_disabled,
    COUNT(*) OVER() AS total_count
  FROM scoped s
  LEFT JOIN public.profiles cp ON cp.id = s.client_id
  LEFT JOIN public.profiles op ON op.id = s.manager_id
  ORDER BY s.created_at DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid) TO service_role;