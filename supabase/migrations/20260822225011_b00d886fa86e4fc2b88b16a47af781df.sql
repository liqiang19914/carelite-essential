-- 客户列表 RPC 升级：关系级客户名 + 全端手机号脱敏（仅平台超管明文）
DROP FUNCTION IF EXISTS public.get_manager_clients(uuid);
CREATE OR REPLACE FUNCTION public.get_manager_clients(p_manager_id uuid)
RETURNS TABLE(
  relation_id uuid,
  client_id uuid,
  status text,
  notes text,
  last_contact_at timestamp with time zone,
  relation_created_at timestamp with time zone,
  customer_name text,
  nickname text,
  phone text,
  avatar_url text,
  privacy_settings jsonb,
  shop_member_number text,
  shop_first_entered_at timestamp with time zone
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH authorized AS (
    SELECT 1
    WHERE auth.uid() = p_manager_id
       OR is_admin(auth.uid())
       OR is_enterprise_member_for_admin(p_manager_id, auth.uid())
  ),
  root_id AS (
    SELECT public.get_enterprise_root_manager_id(p_manager_id) AS rid
  ),
  relation_rows AS (
    SELECT
      cr.id AS relation_id,
      cr.client_id,
      cr.status::text,
      cr.notes,
      cr.last_contact_at,
      cr.created_at AS relation_created_at,
      cr.customer_name
    FROM client_relations cr
    WHERE cr.manager_id = p_manager_id
  ),
  member_only_rows AS (
    SELECT
      sm.id AS relation_id,
      sm.client_id,
      'active'::text AS status,
      ''::text AS notes,
      NULL::timestamptz AS last_contact_at,
      sm.first_entered_at AS relation_created_at,
      NULL::text AS customer_name
    FROM shop_members sm
    WHERE sm.root_manager_id = (SELECT rid FROM root_id)
      AND sm.client_id NOT IN (SELECT r.client_id FROM relation_rows r)
  ),
  combined AS (
    SELECT * FROM relation_rows
    UNION ALL
    SELECT * FROM member_only_rows
  )
  SELECT
    c.relation_id,
    c.client_id,
    c.status,
    c.notes,
    c.last_contact_at,
    c.relation_created_at,
    COALESCE(NULLIF(btrim(c.customer_name), ''), p.nickname::text, '未命名客户') AS customer_name,
    p.nickname::text,
    CASE
      WHEN public.is_admin(auth.uid()) THEN p.phone::text
      WHEN p.phone ~ '^1[0-9]{10}$' THEN left(p.phone, 3) || '****' || right(p.phone, 4)
      ELSE NULL
    END AS phone,
    p.avatar_url,
    COALESCE(p.privacy_settings, '{}'::jsonb) AS privacy_settings,
    sm.member_number AS shop_member_number,
    sm.first_entered_at AS shop_first_entered_at
  FROM combined c
  CROSS JOIN authorized
  LEFT JOIN profiles p ON p.id = c.client_id
  LEFT JOIN shop_members sm
    ON sm.root_manager_id = (SELECT rid FROM root_id)
   AND sm.client_id = c.client_id
  ORDER BY c.relation_created_at DESC;
$function$;

REVOKE ALL ON FUNCTION public.get_manager_clients(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_manager_clients(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_manager_clients(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_manager_clients(uuid) TO service_role;

-- 企业版客户列表同样升级
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
  customer_name text,
  nickname text,
  phone text,
  avatar_url text,
  privacy_settings jsonb,
  owner_manager_id uuid,
  owner_manager_nickname text,
  owner_manager_phone text,
  owner_sub_role text,
  owner_is_disabled boolean,
  shop_member_number text,
  shop_first_entered_at timestamp with time zone,
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
  relation_scoped AS (
    SELECT
      cr.id AS relation_id,
      cr.client_id,
      cr.status::text AS status,
      cr.notes,
      cr.last_contact_at,
      cr.created_at AS relation_created_at,
      cr.manager_id AS owner_manager_id,
      cr.customer_name
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
        OR cr.customer_name ILIKE '%' || v_search || '%'
      )
  ),
  member_only AS (
    SELECT
      sm.id AS relation_id,
      sm.client_id,
      'active'::text AS status,
      ''::text AS notes,
      NULL::timestamptz AS last_contact_at,
      sm.first_entered_at AS relation_created_at,
      v_root AS owner_manager_id,
      NULL::text AS customer_name
    FROM public.shop_members sm
    WHERE sm.root_manager_id = v_root
      AND sm.client_id NOT IN (SELECT r.client_id FROM relation_scoped r)
      AND (
        v_search IS NULL
        OR EXISTS (
          SELECT 1 FROM public.profiles cp
          WHERE cp.id = sm.client_id
            AND (cp.nickname ILIKE '%' || v_search || '%'
                 OR cp.phone ILIKE '%' || v_search || '%')
        )
      )
  ),
  combined AS (
    SELECT * FROM relation_scoped
    UNION ALL
    SELECT * FROM member_only
  )
  SELECT
    c.relation_id,
    c.client_id,
    c.status,
    c.notes,
    c.last_contact_at,
    c.relation_created_at,
    COALESCE(NULLIF(btrim(c.customer_name), ''), cp.nickname::text, '未命名客户') AS customer_name,
    cp.nickname::text,
    CASE
      WHEN public.is_admin(v_uid) THEN cp.phone::text
      WHEN cp.phone ~ '^1[0-9]{10}$' THEN left(cp.phone, 3) || '****' || right(cp.phone, 4)
      ELSE NULL
    END AS phone,
    cp.avatar_url,
    COALESCE(cp.privacy_settings, '{}'::jsonb) AS privacy_settings,
    c.owner_manager_id,
    op.nickname::text AS owner_manager_nickname,
    op.phone::text AS owner_manager_phone,
    COALESCE(op.sub_role, '')::text AS owner_sub_role,
    COALESCE(op.is_disabled, false) AS owner_is_disabled,
    sm.member_number AS shop_member_number,
    sm.first_entered_at AS shop_first_entered_at,
    COUNT(*) OVER() AS total_count
  FROM combined c
  LEFT JOIN public.profiles cp ON cp.id = c.client_id
  LEFT JOIN public.profiles op ON op.id = c.owner_manager_id
  LEFT JOIN public.shop_members sm
    ON sm.root_manager_id = v_root
   AND sm.client_id = c.client_id
  ORDER BY c.relation_created_at DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid) TO authenticated;