-- ============================================================
-- 企业智能体管理：版本表 + 回填 + 克隆/发布/推荐 RPC
-- ============================================================

-- 1) managers 加推荐排序字段
ALTER TABLE public.managers ADD COLUMN IF NOT EXISTS recommend_rank integer;

-- 2) 企业智能体版本表（draft/published 快照）
CREATE TABLE IF NOT EXISTS public.health_manager_agents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  enterprise_id uuid REFERENCES public.enterprises(id) ON DELETE CASCADE,
  name text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published')),
  is_active boolean NOT NULL DEFAULT false,
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  source_manager_id uuid REFERENCES public.managers(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS hma_one_active_per_manager
  ON public.health_manager_agents (manager_id) WHERE is_active = true;

CREATE INDEX IF NOT EXISTS hma_enterprise_idx
  ON public.health_manager_agents (enterprise_id, manager_id, status);

ALTER TABLE public.health_manager_agents ENABLE ROW LEVEL SECURITY;

-- 3) 回填：每个已有 manager 建一个 published+active 智能体快照
INSERT INTO public.health_manager_agents (manager_id, enterprise_id, name, status, is_active, config)
SELECT m.id, m.enterprise_id, COALESCE(NULLIF(trim(m.business_name), ''), '健康管理师'), 'published', true,
  jsonb_build_object(
    'business_name', m.business_name,
    'tagline', m.tagline,
    'intro_personal', m.intro_personal,
    'intro_company', m.intro_company,
    'digital_avatar_image_url', m.digital_avatar_image_url,
    'credentials', m.credentials,
    'knowledge_system_prompt', m.knowledge_system_prompt,
    'knowledge_model', m.knowledge_model,
    'public_qa_enabled', m.public_qa_enabled,
    'public_qa_welcome_message', m.public_qa_welcome_message,
    'public_qa_lead_capture_mode', m.public_qa_lead_capture_mode
  )
FROM public.managers m
WHERE m.enterprise_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.health_manager_agents a
    WHERE a.manager_id = m.id AND a.is_active = true
  );

-- 4) 企业智能体列表（含 active 智能体 + 草稿数 + 推荐状态）
CREATE OR REPLACE FUNCTION public.list_enterprise_agents()
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
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
      (SELECT a.id FROM public.health_manager_agents a WHERE a.manager_id = p.id AND a.is_active LIMIT 1) AS active_agent_id,
      (SELECT a.name FROM public.health_manager_agents a WHERE a.manager_id = p.id AND a.is_active LIMIT 1) AS active_agent_name,
      (SELECT count(*)::int FROM public.health_manager_agents a WHERE a.manager_id = p.id AND a.status = 'draft') AS draft_count
    FROM public.profiles p
    LEFT JOIN public.managers m ON m.id = p.id
    LEFT JOIN public.enterprise_roles r ON r.id = p.enterprise_role_id
    WHERE p.enterprise_id = v_ent AND p.role = 'manager'
  ) x;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_agents() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_enterprise_agents() TO authenticated;

-- 5) 某健管师的草稿列表
CREATE OR REPLACE FUNCTION public.list_agent_drafts(p_manager_id uuid)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
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
  SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = v_uid;
  IF v_ent IS NULL THEN RETURN '[]'::json; END IF;

  SELECT COALESCE(json_agg(x ORDER BY x.created_at DESC), '[]'::json)
  INTO v_result
  FROM (
    SELECT
      a.id, a.manager_id, a.name, a.status, a.source_manager_id,
      sp.nickname AS source_nickname,
      a.created_at
    FROM public.health_manager_agents a
    LEFT JOIN public.profiles sp ON sp.id = a.source_manager_id
    WHERE a.manager_id = p_manager_id AND a.enterprise_id = v_ent AND a.status = 'draft'
  ) x;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_agent_drafts(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_agent_drafts(uuid) TO authenticated;

-- 6) 克隆：把源健管师智能体配置复制为目标健管师的草稿
CREATE OR REPLACE FUNCTION public.clone_manager_agent(
  p_source_manager_id uuid,
  p_target_manager_id uuid,
  p_name text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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
  SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = v_uid;
  IF v_ent IS NULL THEN RETURN json_build_object('error', '无企业归属'); END IF;

  IF NOT EXISTS (SELECT 1 FROM public.managers m WHERE m.id = p_source_manager_id AND m.enterprise_id = v_ent) THEN
    RETURN json_build_object('error', '源健管师不在本企业');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = p_target_manager_id AND p.enterprise_id = v_ent) THEN
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

-- 7) 发布：把草稿配置应用到目标健管师，并置为 active
CREATE OR REPLACE FUNCTION public.publish_manager_agent(p_agent_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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
  SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = v_uid;

  SELECT * INTO v_agent FROM public.health_manager_agents WHERE id = p_agent_id AND enterprise_id = v_ent;
  IF NOT FOUND THEN
    RETURN json_build_object('error', '草稿不存在');
  END IF;
  IF v_agent.status <> 'draft' THEN
    RETURN json_build_object('error', '该版本不是草稿');
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

-- 8) 推荐/顶置：商户端设置本企业健管师的推荐状态与排序
CREATE OR REPLACE FUNCTION public.set_enterprise_agent_recommended(
  p_manager_id uuid,
  p_recommended boolean,
  p_rank integer
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
         updated_at = now()
   WHERE id = p_manager_id;

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.set_enterprise_agent_recommended(uuid, boolean, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_enterprise_agent_recommended(uuid, boolean, integer) TO authenticated;