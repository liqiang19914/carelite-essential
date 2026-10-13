-- feature 149：编辑他人智能体改为可授予权限（agent_edit）。本人操作自己的智能体不受限制。
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
  SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = v_uid;

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