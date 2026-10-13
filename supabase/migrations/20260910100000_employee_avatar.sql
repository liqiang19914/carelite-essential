-- 员工头像：企业中心花名册返回 profiles.avatar_url；客户群列表返回群主头像 owner_avatar_url
-- 两个函数均为 CREATE OR REPLACE 整函数重建，签名不变，幂等可重放。

-- ---------- 1) list_enterprise_sub_accounts：加 p.avatar_url ----------
CREATE OR REPLACE FUNCTION public.list_enterprise_sub_accounts(
  p_enterprise_id uuid DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ent uuid;
  v_owner uuid;
  v_result json;
BEGIN
  IF v_uid IS NULL THEN
    RETURN '[]'::json;
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_members', v_uid) THEN
    RETURN '[]'::json;
  END IF;

  v_ent := COALESCE(
    p_enterprise_id,
    (SELECT ee.enterprise_id
       FROM public.enterprise_employments ee
      WHERE ee.auth_user_id = v_uid
        AND ee.status IN ('active', 'disabled', 'pending')
      ORDER BY ee.is_primary DESC, ee.created_at DESC
      LIMIT 1),
    (SELECT e.id FROM public.enterprises e WHERE e.owner_profile_id = v_uid LIMIT 1),
    (SELECT p.enterprise_id FROM public.profiles p WHERE p.id = v_uid)
  );
  IF v_ent IS NULL THEN
    RETURN '[]'::json;
  END IF;
  IF NOT public.is_enterprise_member(v_ent, v_uid) THEN
    RETURN '[]'::json;
  END IF;

  SELECT e.owner_profile_id INTO v_owner FROM public.enterprises e WHERE e.id = v_ent;

  SELECT COALESCE(json_agg(x ORDER BY x.sort_status, x.created_at DESC), '[]'::json)
  INTO v_result
  FROM (
    SELECT
      ee.id AS employment_id,
      ee.auth_user_id AS id,
      p.nickname,
      p.phone,
      p.avatar_url,
      ee.sub_role,
      ee.enterprise_role_id,
      COALESCE(r.name, CASE WHEN ee.sub_role = 'admin' THEN '管理员' ELSE '健康管理师' END) AS role_name,
      ee.permissions,
      ee.status,
      ee.is_primary,
      COALESCE(p.is_disabled, false) AS is_disabled,
      ee.created_at,
      (SELECT count(*)::int FROM public.client_relations cr WHERE cr.manager_id = ee.auth_user_id) AS client_count,
      (SELECT count(*)::int FROM public.surveys s WHERE s.manager_id = ee.auth_user_id) AS survey_count,
      EXISTS (SELECT 1 FROM public.managers m WHERE m.id = ee.auth_user_id) AS has_manager_card,
      COALESCE(p.wecom_userid, '') AS wecom_userid,
      COALESCE((SELECT m.is_system_default FROM public.managers m WHERE m.id = ee.auth_user_id), false) AS is_system_default,
      CASE ee.status WHEN 'active' THEN 0 WHEN 'pending' THEN 1 WHEN 'disabled' THEN 2 ELSE 3 END AS sort_status
    FROM public.enterprise_employments ee
    JOIN public.profiles p ON p.id = ee.auth_user_id
    LEFT JOIN public.enterprise_roles r ON r.id = ee.enterprise_role_id
    WHERE ee.enterprise_id = v_ent
      AND (v_owner IS NULL OR ee.auth_user_id <> v_owner)
  ) x;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_sub_accounts(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_enterprise_sub_accounts(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_enterprise_sub_accounts(uuid) TO authenticated;

-- ---------- 2) list_wecom_pro_chat_groups：加群主头像 owner_avatar_url ----------
CREATE OR REPLACE FUNCTION public.list_wecom_pro_chat_groups(
  p_keyword text DEFAULT NULL,
  p_owner_userid text DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_keyword text;
  v_is_admin boolean;
  v_my_userid text;
  v_total int;
  v_items jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;
  IF NOT public.wecom_pro_module_open(v_root) THEN
    RAISE EXCEPTION '企微助手 Pro 尚未开通' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('wecom_pro_groups', v_uid) THEN
    RAISE EXCEPTION '没有访问客户群的权限' USING ERRCODE = '42501';
  END IF;

  v_keyword := NULLIF(btrim(COALESCE(p_keyword, '')), '');
  v_is_admin := public.is_enterprise_admin(v_uid);

  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
    v_my_userid := NULLIF(btrim(COALESCE(v_my_userid, '')), '');
    IF v_my_userid IS NULL THEN
      RETURN jsonb_build_object('items', '[]'::jsonb, 'total', 0);
    END IF;
  END IF;

  SELECT count(*) INTO v_total
  FROM public.merchant_wecom_chat_groups g
  WHERE g.root_manager_id = v_root
    AND (v_keyword IS NULL OR g.name ILIKE '%' || v_keyword || '%')
    AND (p_owner_userid IS NULL OR g.owner_userid = p_owner_userid)
    AND (
      v_is_admin
      OR EXISTS (
        SELECT 1 FROM public.merchant_wecom_chat_group_members m
        WHERE m.root_manager_id = v_root AND m.chat_id = g.chat_id AND m.member_id = v_my_userid
      )
    );

  SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row.updated_at DESC NULLS LAST, row.name), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT g.id, g.chat_id, g.name, g.owner_userid, g.member_count, g.notice,
           g.created_at, g.updated_at,
           COALESCE((SELECT p.nickname FROM public.profiles p WHERE p.wecom_userid = g.owner_userid AND COALESCE(p.parent_manager_id, p.id) = v_root LIMIT 1), '') AS owner_name,
           COALESCE((SELECT p.avatar_url FROM public.profiles p WHERE p.wecom_userid = g.owner_userid AND COALESCE(p.parent_manager_id, p.id) = v_root AND p.avatar_url IS NOT NULL AND p.avatar_url <> '' LIMIT 1), '') AS owner_avatar_url,
           -- 前 4 个成员的头像（用于群图标 2×2 拼贴）
           (SELECT ARRAY(
             SELECT av.url FROM (
               SELECT DISTINCT ON (mm.member_id) COALESCE(
                 CASE WHEN mm.member_type = 'external' THEN
                   (SELECT c.avatar_url FROM public.merchant_wecom_contacts c
                     WHERE c.root_manager_id = v_root AND c.external_userid = mm.member_id AND c.avatar_url IS NOT NULL AND c.avatar_url <> '' LIMIT 1)
                 END,
                 CASE WHEN mm.member_type = 'member' THEN
                   (SELECT p.avatar_url FROM public.profiles p
                     WHERE p.wecom_userid = mm.member_id AND COALESCE(p.parent_manager_id, p.id) = v_root AND p.avatar_url IS NOT NULL AND p.avatar_url <> '' LIMIT 1)
                 END,
                 ''
               ) AS url
               FROM public.merchant_wecom_chat_group_members mm
               WHERE mm.root_manager_id = v_root AND mm.chat_id = g.chat_id
               ORDER BY mm.member_id
             ) av WHERE av.url IS NOT NULL AND av.url <> '' LIMIT 4
           )) AS avatars
    FROM public.merchant_wecom_chat_groups g
    WHERE g.root_manager_id = v_root
      AND (v_keyword IS NULL OR g.name ILIKE '%' || v_keyword || '%')
      AND (p_owner_userid IS NULL OR g.owner_userid = p_owner_userid)
      AND (
        v_is_admin
        OR EXISTS (
          SELECT 1 FROM public.merchant_wecom_chat_group_members m
          WHERE m.root_manager_id = v_root AND m.chat_id = g.chat_id AND m.member_id = v_my_userid
        )
      )
    ORDER BY g.updated_at DESC NULLS LAST, g.name
    LIMIT LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100)
    OFFSET (GREATEST(COALESCE(p_page, 1), 1) - 1) * LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100)
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_pro_chat_groups(text, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_pro_chat_groups(text, text, int, int) TO authenticated;

NOTIFY pgrst, 'reload schema';
