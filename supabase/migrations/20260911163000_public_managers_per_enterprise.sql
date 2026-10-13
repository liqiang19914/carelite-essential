-- 前台公开健管师列表改为按「企业就业关系」判定角色
--
-- 背景：同一自然人可以在 A 商户是（超级）管理员、在 B 商户是健康管理师。
-- 权威角色在 enterprise_employments（按企业一行），profiles.sub_role 只是
-- 「主就业」的全局镜像，切换主企业后会翻转。旧版 list_public_enterprise_managers
-- 直接按 profiles.sub_role='health_manager' 过滤，导致跨企业任职的健管师
-- 在其任职商户的小程序前台列表里消失（典型：韩文龙）。
--
-- 新口径：
--  1. 由 root 定位商户企业 enterprise_id；
--  2. 该企业内 status=active、角色 code=health_manager 的就业者才展示；
--  3. 历史老账号（无就业行）保留 profiles 镜像兜底，避免存量商户掉人；
--  4. 停用按企业就业状态判定（disabled/left 不展示），全局 is_disabled 仍是总闸。

CREATE OR REPLACE FUNCTION public.list_public_enterprise_managers(p_manager_id uuid DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO public
AS $function$
DECLARE
  v_root uuid;
  v_ent uuid;
  v_result json;
BEGIN
  IF p_manager_id IS NULL THEN
    SELECT value::uuid INTO v_root
      FROM public.system_settings
     WHERE key = 'platform_manager_root_id';
  ELSE
    SELECT COALESCE(p.parent_manager_id, p.id) INTO v_root
    FROM public.profiles p
    WHERE p.id = p_manager_id;
  END IF;

  IF v_root IS NULL THEN
    RETURN '[]'::json;
  END IF;

  -- root 对应的商户企业：root 账号的企业归属优先，其次其名下 owner 企业
  SELECT COALESCE(
    (SELECT enterprise_id FROM public.profiles
      WHERE id = v_root AND enterprise_id IS NOT NULL LIMIT 1),
    (SELECT id FROM public.enterprises
      WHERE owner_profile_id = v_root LIMIT 1)
  ) INTO v_ent;

  SELECT json_agg(
    json_build_object(
      'manager_id', m.id,
      'short_code', m.short_code,
      'display_name', COALESCE(NULLIF(m.partner_card_display_name, ''), ep.nickname, '健康管理师'),
      'avatar_url', COALESCE(NULLIF(m.digital_avatar_image_url, ''), NULLIF(m.partner_card_avatar_url, ''), NULLIF(ep.avatar_url, '')),
      'tagline', NULLIF(m.tagline, ''),
      'intro_personal', NULLIF(m.intro_personal, ''),
      'company_name', NULLIF(COALESCE(m.company_name, m.partner_card_company_name, m.business_name), ''),
      'is_recommended', COALESCE(m.is_recommended, false),
      'credentials', COALESCE(m.credentials, ARRAY[]::text[]),
      'ai_enabled', COALESCE(m.public_qa_enabled, false),
      'consultation_count', (
        SELECT COUNT(DISTINCT q.visitor_token)
        FROM public.manager_public_qa_sessions q
        WHERE q.manager_id = m.id
      )
    )
    ORDER BY COALESCE(m.is_recommended, false) DESC, ep.created_at ASC
  ) INTO v_result
  FROM (
    -- 新口径：该商户企业内的就业者（每人取最新一条非 left 就业行）
    SELECT DISTINCT ON (ee.auth_user_id)
           ee.auth_user_id AS uid,
           ee.status AS emp_status,
           COALESCE(r.code, ee.sub_role) AS role_code
      FROM public.enterprise_employments ee
      LEFT JOIN public.enterprise_roles r ON r.id = ee.enterprise_role_id
     WHERE v_ent IS NOT NULL
       AND ee.enterprise_id = v_ent
     ORDER BY ee.auth_user_id,
              CASE ee.status WHEN 'left' THEN 1 ELSE 0 END,
              ee.created_at DESC

    UNION ALL

    -- 历史兜底：直属 root、且在该企业没有任何就业行的老账号（镜像字段即唯一角色）
    SELECT p.id AS uid,
           CASE WHEN p.is_disabled THEN 'disabled' ELSE 'active' END AS emp_status,
           p.sub_role AS role_code
      FROM public.profiles p
     WHERE p.parent_manager_id = v_root
       AND p.role = 'manager'
       AND (v_ent IS NULL
            OR NOT EXISTS (
              SELECT 1 FROM public.enterprise_employments ee2
               WHERE ee2.auth_user_id = p.id AND ee2.enterprise_id = v_ent
            ))
  ) mem
  JOIN public.profiles ep ON ep.id = mem.uid
  JOIN public.managers m ON m.id = ep.id
  WHERE ep.id <> v_root
    AND mem.emp_status = 'active'
    AND ep.is_disabled = false
    AND mem.role_code = 'health_manager'
    AND COALESCE(m.is_example, false) = false
    AND COALESCE(m.is_public_visible, true);

  RETURN COALESCE(v_result, '[]'::json);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.list_public_enterprise_managers(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_public_enterprise_managers(uuid) TO anon, authenticated;
