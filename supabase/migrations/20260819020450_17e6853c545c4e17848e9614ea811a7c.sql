-- 商户端客户列表/详情透出商城会员信息（feature 188）
-- get_manager_clients / get_enterprise_clients_with_owner 各加两列：
--   shop_member_number    当前企业根下的会员编号（无 = 尚未登记）
--   shop_first_entered_at 首次进店时间
-- 只返回当前企业根这一条，不返回该客户注册过的全部商城（跨商城隔离）。
-- 返回类型变了（增列）→ 必须先 DROP 再 CREATE。

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
  privacy_settings jsonb,
  shop_member_number text,
  shop_first_entered_at timestamp with time zone
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
    COALESCE(p.privacy_settings, '{}'::jsonb) AS privacy_settings,
    sm.member_number AS shop_member_number,
    sm.first_entered_at AS shop_first_entered_at
  FROM client_relations cr
  LEFT JOIN profiles p ON p.id = cr.client_id
  LEFT JOIN public.shop_members sm
    ON sm.root_manager_id = public.get_enterprise_root_manager_id(p_manager_id)
   AND sm.client_id = cr.client_id
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
    sm.member_number AS shop_member_number,
    sm.first_entered_at AS shop_first_entered_at,
    COUNT(*) OVER() AS total_count
  FROM scoped s
  LEFT JOIN public.profiles cp ON cp.id = s.client_id
  LEFT JOIN public.profiles op ON op.id = s.manager_id
  LEFT JOIN public.shop_members sm
    ON sm.root_manager_id = v_root
   AND sm.client_id = s.client_id
  ORDER BY s.created_at DESC
  LIMIT v_limit
  OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_enterprise_clients_with_owner(integer, integer, text, uuid) TO service_role;