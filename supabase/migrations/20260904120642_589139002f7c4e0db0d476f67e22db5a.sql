-- ============================================================
-- Feature 428：多商户入职与离职 —— 企业查询/统计收口（就业口径）
-- 1) 新增 list_enterprise_sub_accounts(p_enterprise_id)：企业中心员工列表按本企业就业行
-- 2) list_enterprise_health_managers / list_enterprise_agents 成员集合改就业口径（owner + 就业行，含 left，附 status）
-- 3) get_my_permissions 加可选 p_enterprise_id：按当前企业上下文就业行取权限，无上下文回退主就业，再回退旧镜像
-- 4) clone_manager_agent / set_enterprise_agent_recommended 成员校验改就业口径；调用者企业解析改就业上下文优先
-- 5) leave_enterprise_employment：解除就业（幂等、客户交接预检、主就业转移、镜像清理与 role 回退）
-- 全部幂等；加参函数先 DROP 旧签名再建新签名（默认参数向后兼容）。
-- ============================================================

-- ---------- 1) 企业中心员工列表（就业口径） ----------
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

-- ---------- 2) 健管师列表（就业口径成员集合；保留原字段并附 status） ----------
DROP FUNCTION IF EXISTS public.list_enterprise_health_managers();
CREATE OR REPLACE FUNCTION public.list_enterprise_health_managers(
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
  IF NOT public.has_enterprise_permission('health_managers', v_uid) THEN
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

  SELECT COALESCE(json_agg(x ORDER BY x.sort, x.nickname), '[]'::json)
  INTO v_result
  FROM (
    SELECT
      p.id,
      p.nickname,
      p.phone,
      COALESCE(emp.sub_role, p.sub_role) AS sub_role,
      p.is_disabled,
      emp.status,
      COALESCE(r.name, '健康管理师') AS role_name,
      COALESCE(r.code, 'health_manager') AS role_code,
      (SELECT count(*)::int FROM public.client_relations cr WHERE cr.manager_id = p.id AND cr.status = 'active') AS client_count,
      (SELECT count(*)::int FROM public.manager_public_qa_sessions s WHERE s.manager_id = p.id) AS qa_count,
      (SELECT count(*)::int FROM public.manager_knowledge_documents d WHERE d.manager_id = p.id) AS knowledge_count,
      EXISTS (SELECT 1 FROM public.managers m WHERE m.id = p.id) AS has_agent,
      COALESCE((SELECT m.is_recommended FROM public.managers m WHERE m.id = p.id), false) AS is_recommended,
      COALESCE((SELECT m.knowledge_index_status FROM public.managers m WHERE m.id = p.id), 'none') AS knowledge_index_status,
      CASE WHEN v_owner = p.id THEN 0 ELSE 1 END AS sort
    FROM (
      SELECT e2.owner_profile_id AS uid FROM public.enterprises e2
       WHERE e2.id = v_ent AND e2.owner_profile_id IS NOT NULL
      UNION
      SELECT ee.auth_user_id FROM public.enterprise_employments ee
       WHERE ee.enterprise_id = v_ent
    ) mem
    JOIN public.profiles p ON p.id = mem.uid AND p.role = 'manager'
    LEFT JOIN LATERAL (
      SELECT ee.status, ee.sub_role, ee.enterprise_role_id
      FROM public.enterprise_employments ee
      WHERE ee.auth_user_id = mem.uid AND ee.enterprise_id = v_ent
      ORDER BY CASE ee.status WHEN 'left' THEN 1 ELSE 0 END, ee.created_at DESC
      LIMIT 1
    ) emp ON true
    LEFT JOIN public.enterprise_roles r ON r.id = emp.enterprise_role_id
  ) x;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_health_managers(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_enterprise_health_managers(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_enterprise_health_managers(uuid) TO authenticated;

-- ---------- 3) 企业智能体列表（就业口径成员集合） ----------
DROP FUNCTION IF EXISTS public.list_enterprise_agents();
CREATE OR REPLACE FUNCTION public.list_enterprise_agents(
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
  v_result json;
BEGIN
  IF v_uid IS NULL THEN RETURN '[]'::json; END IF;
  IF NOT public.has_enterprise_permission('agents', v_uid) THEN
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
  IF v_ent IS NULL THEN RETURN '[]'::json; END IF;
  IF NOT public.is_enterprise_member(v_ent, v_uid) THEN
    RETURN '[]'::json;
  END IF;

  SELECT COALESCE(json_agg(x ORDER BY x.nickname), '[]'::json)
  INTO v_result
  FROM (
    SELECT
      p.id AS manager_id,
      p.nickname,
      p.phone,
      COALESCE(r.name, '健康管理师') AS role_name,
      emp.status,
      COALESCE(m.is_recommended, false) AS is_recommended,
      m.recommend_rank,
      COALESCE(m.is_public_visible, true) AS is_public_visible,
      (SELECT a.id FROM public.health_manager_agents a WHERE a.manager_id = p.id AND a.is_active LIMIT 1) AS active_agent_id,
      (SELECT a.name FROM public.health_manager_agents a WHERE a.manager_id = p.id AND a.is_active LIMIT 1) AS active_agent_name,
      (SELECT count(*)::int FROM public.health_manager_agents a WHERE a.manager_id = p.id AND a.status = 'draft') AS draft_count,
      (COALESCE(m.public_qa_enabled, false) AND COALESCE(m.knowledge_index_status, '') = 'ready') AS qa_ready
    FROM (
      SELECT e2.owner_profile_id AS uid FROM public.enterprises e2
       WHERE e2.id = v_ent AND e2.owner_profile_id IS NOT NULL
      UNION
      SELECT ee.auth_user_id FROM public.enterprise_employments ee
       WHERE ee.enterprise_id = v_ent
    ) mem
    JOIN public.profiles p ON p.id = mem.uid AND p.role = 'manager'
    LEFT JOIN LATERAL (
      SELECT ee.status
      FROM public.enterprise_employments ee
      WHERE ee.auth_user_id = mem.uid AND ee.enterprise_id = v_ent
      ORDER BY CASE ee.status WHEN 'left' THEN 1 ELSE 0 END, ee.created_at DESC
      LIMIT 1
    ) emp ON true
    LEFT JOIN public.managers m ON m.id = p.id
    LEFT JOIN public.enterprise_roles r ON r.id = emp.enterprise_role_id
  ) x;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_agents(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_enterprise_agents(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_enterprise_agents(uuid) TO authenticated;

-- ---------- 4) get_my_permissions：就业口径（上下文 → 主就业 → 旧镜像） ----------
DROP FUNCTION IF EXISTS public.get_my_permissions();
CREATE OR REPLACE FUNCTION public.get_my_permissions(
  p_enterprise_id uuid DEFAULT NULL
)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM public.enterprises e WHERE e.owner_profile_id = auth.uid())
    THEN (SELECT COALESCE(array_agg(code ORDER BY code), ARRAY[]::text[]) FROM public.permission_definitions)
    ELSE COALESCE(
      (
        SELECT array_agg(rp.permission_code ORDER BY rp.permission_code)
        FROM public.enterprise_role_permissions rp
        WHERE rp.role_id = (
          SELECT ee.enterprise_role_id
          FROM public.enterprise_employments ee
          WHERE ee.auth_user_id = auth.uid()
            AND ee.status IN ('active', 'pending')
            AND ee.enterprise_role_id IS NOT NULL
            AND (p_enterprise_id IS NULL OR ee.enterprise_id = p_enterprise_id)
          ORDER BY ee.is_primary DESC, ee.created_at DESC
          LIMIT 1
        )
      ),
      (
        SELECT array_agg(rp.permission_code ORDER BY rp.permission_code)
        FROM public.profiles p
        JOIN public.enterprise_role_permissions rp ON rp.role_id = p.enterprise_role_id
        WHERE p.id = auth.uid()
      ),
      ARRAY[]::text[]
    )
  END;
$function$;

REVOKE ALL ON FUNCTION public.get_my_permissions(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_permissions(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_permissions(uuid) TO authenticated;

-- ---------- 5) 离职/成员校验函数收口为就业口径 ----------
CREATE OR REPLACE FUNCTION public.set_enterprise_agent_recommended(
  p_manager_id uuid,
  p_recommended boolean,
  p_rank integer,
  p_is_public_visible boolean DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ent uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN json_build_object('error', '未登录'); END IF;
  IF NOT public.has_enterprise_permission('agents', v_uid) THEN
    RETURN json_build_object('error', '无智能体管理权限');
  END IF;

  v_ent := COALESCE(
    (SELECT ee.enterprise_id
       FROM public.enterprise_employments ee
      WHERE ee.auth_user_id = v_uid
        AND ee.status IN ('active', 'disabled', 'pending')
      ORDER BY ee.is_primary DESC, ee.created_at DESC
      LIMIT 1),
    (SELECT e.id FROM public.enterprises e WHERE e.owner_profile_id = v_uid LIMIT 1),
    (SELECT p.enterprise_id FROM public.profiles p WHERE p.id = v_uid)
  );
  IF v_ent IS NULL THEN RETURN json_build_object('error', '无企业归属'); END IF;

  IF NOT public.is_enterprise_member(v_ent, p_manager_id) THEN
    RETURN json_build_object('error', '健管师不在本企业');
  END IF;

  UPDATE public.managers
     SET is_recommended = p_recommended,
         recommend_rank = CASE WHEN p_recommended THEN p_rank ELSE NULL END,
         is_public_visible = CASE WHEN p_is_public_visible IS NULL THEN is_public_visible ELSE p_is_public_visible END,
         updated_at = now()
   WHERE id = p_manager_id;

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.set_enterprise_agent_recommended(uuid, boolean, integer, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_enterprise_agent_recommended(uuid, boolean, integer, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.clone_manager_agent(p_source_manager_id uuid, p_target_manager_id uuid, p_name text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ent uuid;
  v_config jsonb;
  v_agent_id uuid;
BEGIN
  IF v_uid IS NULL THEN RETURN json_build_object('error', '未登录'); END IF;
  IF NOT public.has_enterprise_permission('agents', v_uid) THEN
    RETURN json_build_object('error', '无智能体管理权限');
  END IF;
  IF p_target_manager_id IS DISTINCT FROM v_uid
     AND NOT public.has_enterprise_permission('agent_edit', v_uid) THEN
    RETURN json_build_object('error', '你的角色没有「编辑他人的智能体」权限，请让超级管理员在「企业中心 → 角色权限」里勾选后再试');
  END IF;

  v_ent := COALESCE(
    (SELECT ee.enterprise_id
       FROM public.enterprise_employments ee
      WHERE ee.auth_user_id = v_uid
        AND ee.status IN ('active', 'disabled', 'pending')
      ORDER BY ee.is_primary DESC, ee.created_at DESC
      LIMIT 1),
    (SELECT e.id FROM public.enterprises e WHERE e.owner_profile_id = v_uid LIMIT 1),
    (SELECT p.enterprise_id FROM public.profiles p WHERE p.id = v_uid)
  );
  IF v_ent IS NULL THEN RETURN json_build_object('error', '无企业归属'); END IF;

  IF NOT public.is_enterprise_member(v_ent, p_source_manager_id) THEN
    RETURN json_build_object('error', '源健管师不在本企业');
  END IF;
  IF NOT public.is_enterprise_member(v_ent, p_target_manager_id) THEN
    RETURN json_build_object('error', '目标健管师不在本企业');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.managers m WHERE m.id = p_target_manager_id) THEN
    RETURN json_build_object('error', '目标健管师尚未建立智能体，请先在健管师管理里创建');
  END IF;

  SELECT jsonb_build_object(
    'business_name', m.business_name, 'tagline', m.tagline, 'intro_personal', m.intro_personal,
    'intro_company', m.intro_company, 'digital_avatar_image_url', m.digital_avatar_image_url,
    'credentials', m.credentials, 'knowledge_system_prompt', m.knowledge_system_prompt,
    'knowledge_model', m.knowledge_model, 'public_qa_enabled', m.public_qa_enabled,
    'public_qa_welcome_message', m.public_qa_welcome_message, 'public_qa_lead_capture_mode', m.public_qa_lead_capture_mode
  ) INTO v_config FROM public.managers m WHERE m.id = p_source_manager_id;

  INSERT INTO public.health_manager_agents (manager_id, enterprise_id, name, status, is_active, config, source_manager_id)
  VALUES (p_target_manager_id, v_ent, COALESCE(NULLIF(trim(p_name), ''), '克隆草稿'), 'draft', false, v_config, p_source_manager_id)
  RETURNING id INTO v_agent_id;

  RETURN json_build_object('success', true, 'agent_id', v_agent_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.clone_manager_agent(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.clone_manager_agent(uuid, uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.publish_manager_agent(p_agent_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ent uuid;
  v_agent record;
BEGIN
  IF v_uid IS NULL THEN RETURN json_build_object('error', '未登录'); END IF;
  IF NOT public.has_enterprise_permission('agents', v_uid) THEN
    RETURN json_build_object('error', '无智能体管理权限');
  END IF;

  v_ent := COALESCE(
    (SELECT ee.enterprise_id
       FROM public.enterprise_employments ee
      WHERE ee.auth_user_id = v_uid
        AND ee.status IN ('active', 'disabled', 'pending')
      ORDER BY ee.is_primary DESC, ee.created_at DESC
      LIMIT 1),
    (SELECT e.id FROM public.enterprises e WHERE e.owner_profile_id = v_uid LIMIT 1),
    (SELECT p.enterprise_id FROM public.profiles p WHERE p.id = v_uid)
  );

  SELECT * INTO v_agent FROM public.health_manager_agents WHERE id = p_agent_id AND enterprise_id = v_ent;
  IF NOT FOUND THEN
    RETURN json_build_object('error', '草稿不存在');
  END IF;
  IF v_agent.status <> 'draft' THEN
    RETURN json_build_object('error', '该版本不是草稿');
  END IF;
  IF v_agent.manager_id IS DISTINCT FROM v_uid
     AND NOT public.has_enterprise_permission('agent_edit', v_uid) THEN
    RETURN json_build_object('error', '你的角色没有「编辑他人的智能体」权限，请让超级管理员在「企业中心 → 角色权限」里勾选后再试');
  END IF;

  UPDATE public.managers m
     SET business_name = COALESCE(v_agent.config->>'business_name', m.business_name),
         tagline = COALESCE(v_agent.config->>'tagline', m.tagline),
         intro_personal = COALESCE(v_agent.config->>'intro_personal', m.intro_personal),
         intro_company = COALESCE(v_agent.config->>'intro_company', m.intro_company),
         digital_avatar_image_url = COALESCE(v_agent.config->>'digital_avatar_image_url', m.digital_avatar_image_url),
         credentials = COALESCE((v_agent.config->'credentials')::text[], m.credentials),
         knowledge_system_prompt = COALESCE(v_agent.config->>'knowledge_system_prompt', m.knowledge_system_prompt),
         knowledge_model = COALESCE(v_agent.config->>'knowledge_model', m.knowledge_model),
         public_qa_enabled = COALESCE((v_agent.config->>'public_qa_enabled')::boolean, m.public_qa_enabled),
         public_qa_welcome_message = COALESCE(v_agent.config->>'public_qa_welcome_message', m.public_qa_welcome_message),
         public_qa_lead_capture_mode = COALESCE(v_agent.config->>'public_qa_lead_capture_mode', m.public_qa_lead_capture_mode),
         updated_at = now()
   WHERE m.id = v_agent.manager_id;

  UPDATE public.health_manager_agents SET is_active = false, updated_at = now()
   WHERE manager_id = v_agent.manager_id AND is_active = true AND id <> p_agent_id;

  UPDATE public.health_manager_agents SET status = 'published', is_active = true, updated_at = now()
   WHERE id = p_agent_id;

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.publish_manager_agent(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.publish_manager_agent(uuid) TO authenticated;

-- ---------- 6) 解除就业（幂等；客户交接预检；主就业转移；镜像清理与 role 回退） ----------
-- role 回退策略（427 兜底已核对）：
--   · 仍有其他有效就业 → 若离职行是主就业，set_primary_employment 自动迁移镜像，role 不动；
--   · 无有效就业且本人仍是某企业主/平台 admin → role 保留（工作台走自有企业）；
--   · 其余 → role 回 'user'（账号保留、客户端可达），镜像列清空；再入职由
--     create_enterprise_employment 的 user→manager 升级镜像恢复 manager 身份。
CREATE OR REPLACE FUNCTION public.leave_enterprise_employment(
  p_auth_user_id uuid,
  p_enterprise_id uuid,
  p_operator_auth_user_id uuid DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row public.enterprise_employments;
  v_next_id uuid;
  v_client_count integer;
  v_enterprise_name text;
BEGIN
  IF p_auth_user_id IS NULL OR p_enterprise_id IS NULL THEN
    RAISE EXCEPTION '参数缺失，无法解除就业' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.enterprises
    WHERE id = p_enterprise_id AND owner_profile_id = p_auth_user_id
  ) THEN
    RAISE EXCEPTION '企业主不能解除本企业的就业关系' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.managers m
    WHERE m.id = p_auth_user_id AND m.is_system_default
  ) THEN
    RAISE EXCEPTION '系统预置健康管理师不支持解除就业' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_row
  FROM public.enterprise_employments
  WHERE auth_user_id = p_auth_user_id
    AND enterprise_id = p_enterprise_id
    AND status IN ('active', 'disabled', 'pending')
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    -- 已是 left 的历史行：幂等成功
    IF EXISTS (
      SELECT 1 FROM public.enterprise_employments
      WHERE auth_user_id = p_auth_user_id
        AND enterprise_id = p_enterprise_id
        AND status = 'left'
    ) THEN
      RETURN json_build_object('success', true, 'already_left', true);
    END IF;
    RAISE EXCEPTION '该员工不在本企业，无法解除就业' USING ERRCODE = 'P0001';
  END IF;

  -- 客户交接预检：该员工名下全部有效客户（跨企业保守口径，沿用既有转让流程）
  SELECT count(*) INTO v_client_count
  FROM public.client_relations
  WHERE manager_id = p_auth_user_id AND status = 'active';
  IF v_client_count > 0 THEN
    RETURN json_build_object(
      'blocked', true,
      'client_count', v_client_count,
      'message', format('该员工名下还有 %s 位客户未交接，请先在员工详情「客户」页把客户转让给企业主或其他员工，再解除就业', v_client_count)
    );
  END IF;

  UPDATE public.enterprise_employments
     SET status = 'left', is_primary = false, updated_at = now()
   WHERE id = v_row.id;

  SELECT ee.id INTO v_next_id
  FROM public.enterprise_employments ee
  WHERE ee.auth_user_id = p_auth_user_id
    AND ee.status IN ('active', 'disabled', 'pending')
  ORDER BY ee.created_at ASC
  LIMIT 1;

  IF v_next_id IS NOT NULL THEN
    IF v_row.is_primary THEN
      PERFORM public.set_primary_employment(p_auth_user_id, v_next_id, p_operator_auth_user_id);
    END IF;
  ELSE
    UPDATE public.profiles
       SET role = CASE
             WHEN role = 'admin' THEN role
             WHEN EXISTS (SELECT 1 FROM public.enterprises e WHERE e.owner_profile_id = p_auth_user_id) THEN role
             ELSE 'user'::public.user_role
           END,
           parent_manager_id = NULL,
           enterprise_id = NULL,
           enterprise_role_id = NULL,
           sub_role = NULL,
           permissions = '{}'::jsonb,
           primary_employment_id = NULL,
           is_disabled = false,
           disabled_at = NULL,
           disabled_reason = NULL,
           updated_at = now()
     WHERE id = p_auth_user_id;
  END IF;

  IF p_operator_auth_user_id IS NOT NULL THEN
    SELECT name INTO v_enterprise_name FROM public.enterprises WHERE id = p_enterprise_id;
    INSERT INTO public.operation_logs (user_id, action, detail, module, metadata)
    VALUES (
      p_operator_auth_user_id,
      '解除企业就业',
      format('解除了员工（%s）在「%s」的就业关系',
        COALESCE((SELECT nickname FROM public.profiles WHERE id = p_auth_user_id), p_auth_user_id::text),
        COALESCE(v_enterprise_name, '')),
      '企业中心',
      jsonb_build_object(
        'employment_id', v_row.id,
        'auth_user_id', p_auth_user_id,
        'enterprise_id', p_enterprise_id,
        'promoted_employment_id', v_next_id,
        'remaining_valid', v_next_id IS NOT NULL
      )
    );
  END IF;

  RETURN json_build_object(
    'success', true,
    'employment_id', v_row.id,
    'promoted_employment_id', v_next_id,
    'remaining_valid', v_next_id IS NOT NULL
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.leave_enterprise_employment(uuid, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.leave_enterprise_employment(uuid, uuid, uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.leave_enterprise_employment(uuid, uuid, uuid) TO service_role;