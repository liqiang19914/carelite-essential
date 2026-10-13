-- 前台公开健管师列表：按企业就业关系判角色 + 按推荐序号排序
--
-- 背景 1（角色）：同一自然人可跨商户任职（A 商户超管、B 商户健管师），
--   profiles.sub_role 只是主就业的全局镜像，跨企业任职时口径会串。
--   改为以 enterprise_employments（企业内 active + 角色 health_manager）为准，
--   无就业行的历史账号保留 parent_manager_id + 镜像字段兜底。
-- 背景 2（排序）：管理端「推荐与排序」填的序号此前前台不消费，
--   后入驻者永远垫底。补上 recommend_rank 升序（空号排最后）。
-- 实现：不用 DISTINCT ON + UNION（该写法在执行链路上曾触发 42601），
--   改用与 list_enterprise_health_managers 相同的成员集合 + LATERAL 模式。

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
    ORDER BY COALESCE(m.is_recommended, false) DESC,
             m.recommend_rank ASC NULLS LAST,
             ep.created_at ASC
  ) INTO v_result
  FROM (
    -- 候选成员：企业 owner + 本企业就业者 + 直属 root 的历史账号（兜底）
    SELECT e2.owner_profile_id AS uid
      FROM public.enterprises e2
     WHERE e2.id = v_ent AND e2.owner_profile_id IS NOT NULL
    UNION
    SELECT ee.auth_user_id
      FROM public.enterprise_employments ee
     WHERE ee.enterprise_id = v_ent
    UNION
    SELECT p.id
      FROM public.profiles p
     WHERE p.parent_manager_id = v_root
       AND p.role = 'manager'
  ) mem
  JOIN public.profiles ep ON ep.id = mem.uid
  JOIN public.managers m ON m.id = ep.id
  LEFT JOIN LATERAL (
    -- 本企业最新一条就业行（非 left 优先，其次最新）
    SELECT ee.status AS emp_status,
           COALESCE(r.code, ee.sub_role) AS role_code
      FROM public.enterprise_employments ee
      LEFT JOIN public.enterprise_roles r ON r.id = ee.enterprise_role_id
     WHERE ee.auth_user_id = mem.uid
       AND ee.enterprise_id = v_ent
     ORDER BY CASE ee.status WHEN 'left' THEN 1 ELSE 0 END,
              ee.created_at DESC
     LIMIT 1
  ) emp ON true
  WHERE ep.id <> v_root
    AND ep.role = 'manager'
    AND ep.is_disabled = false
    -- 在职判定：有就业行看就业状态；无就业行的历史账号看全局停用开关
    AND COALESCE(emp.emp_status, CASE WHEN ep.is_disabled THEN 'disabled' ELSE 'active' END) = 'active'
    -- 角色判定：有就业行看企业角色 code；无就业行看镜像字段
    AND COALESCE(emp.role_code, ep.sub_role) = 'health_manager'
    AND COALESCE(m.is_example, false) = false
    AND COALESCE(m.is_public_visible, true);

  RETURN COALESCE(v_result, '[]'::json);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.list_public_enterprise_managers(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_public_enterprise_managers(uuid) TO anon, authenticated;
