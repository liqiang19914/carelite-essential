-- 健管师「前台展示」开关：关闭后前台列表不再显示，名片与咨询链接仍可访问
ALTER TABLE public.managers
  ADD COLUMN IF NOT EXISTS is_public_visible boolean NOT NULL DEFAULT true;

-- 推荐/顶置设置扩展为同时可写「前台展示」开关（不传时保持原值）
DROP FUNCTION IF EXISTS public.set_enterprise_agent_recommended(uuid, boolean, integer);

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
  SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = v_uid;

  IF NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = p_manager_id AND p.enterprise_id = v_ent) THEN
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

-- 前台公开列表：隐藏已关闭前台展示的健管师（字段不进匿名返回）
CREATE OR REPLACE FUNCTION public.list_public_enterprise_managers(p_manager_id uuid DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_root uuid;
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
  FROM public.profiles ep
  JOIN public.managers m ON m.id = ep.id
  WHERE ep.parent_manager_id = v_root
    AND ep.role = 'manager'
    AND ep.sub_role = 'health_manager'
    AND ep.is_disabled = false
    AND COALESCE(m.is_example, false) = false
    AND COALESCE(m.is_public_visible, true);

  RETURN COALESCE(v_result, '[]'::json);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.list_public_enterprise_managers(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_public_enterprise_managers(uuid) TO anon, authenticated;

-- 企业智能体管理列表补「前台展示」字段，供管理端开关展示当前状态
CREATE OR REPLACE FUNCTION public.list_enterprise_agents()
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
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
  SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = v_uid;
  IF v_ent IS NULL THEN RETURN '[]'::json; END IF;

  SELECT COALESCE(json_agg(x ORDER BY x.nickname), '[]'::json)
  INTO v_result
  FROM (
    SELECT
      p.id AS manager_id,
      p.nickname,
      p.phone,
      COALESCE(r.name, '健康管理师') AS role_name,
      COALESCE(m.is_recommended, false) AS is_recommended,
      m.recommend_rank,
      COALESCE(m.is_public_visible, true) AS is_public_visible,
      (SELECT a.id FROM public.health_manager_agents a WHERE a.manager_id = p.id AND a.is_active LIMIT 1) AS active_agent_id,
      (SELECT a.name FROM public.health_manager_agents a WHERE a.manager_id = p.id AND a.is_active LIMIT 1) AS active_agent_name,
      (SELECT count(*)::int FROM public.health_manager_agents a WHERE a.manager_id = p.id AND a.status = 'draft') AS draft_count,
      (COALESCE(m.public_qa_enabled, false) AND COALESCE(m.knowledge_index_status, '') = 'ready') AS qa_ready
    FROM public.profiles p
    LEFT JOIN public.managers m ON m.id = p.id
    LEFT JOIN public.enterprise_roles r ON r.id = p.enterprise_role_id
    WHERE p.enterprise_id = v_ent AND p.role = 'manager'
  ) x;

  RETURN v_result;
END;
$function$;