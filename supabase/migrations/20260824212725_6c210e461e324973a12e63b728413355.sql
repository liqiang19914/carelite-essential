CREATE OR REPLACE FUNCTION public.ensure_agent_for_manager(p_manager_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_ent uuid;
  v_nick text;
  v_m public.managers%ROWTYPE;
BEGIN
  SELECT p.enterprise_id, p.nickname INTO v_ent, v_nick
  FROM public.profiles p
  WHERE p.id = p_manager_id AND p.role = 'manager';

  IF v_ent IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_m FROM public.managers WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.health_manager_agents a
    WHERE a.manager_id = p_manager_id AND a.is_active = true AND a.enterprise_id = v_ent
  ) THEN
    RETURN;
  END IF;

  INSERT INTO public.health_manager_agents (manager_id, enterprise_id, name, status, is_active, config)
  VALUES (
    p_manager_id,
    v_ent,
    COALESCE(NULLIF(trim(v_m.business_name), ''), NULLIF(trim(v_nick), ''), '健康管理师'),
    'published',
    true,
    jsonb_build_object(
      'business_name', v_m.business_name,
      'tagline', v_m.tagline,
      'intro_personal', v_m.intro_personal,
      'intro_company', v_m.intro_company,
      'digital_avatar_image_url', v_m.digital_avatar_image_url,
      'credentials', v_m.credentials,
      'knowledge_system_prompt', v_m.knowledge_system_prompt,
      'knowledge_model', v_m.knowledge_model,
      'public_qa_enabled', v_m.public_qa_enabled,
      'public_qa_welcome_message', v_m.public_qa_welcome_message,
      'public_qa_lead_capture_mode', v_m.public_qa_lead_capture_mode
    )
  )
  ON CONFLICT (manager_id) WHERE is_active DO NOTHING;
END;
$function$;

REVOKE ALL ON FUNCTION public.ensure_agent_for_manager(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ensure_agent_for_manager(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.trg_managers_ensure_agent()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  PERFORM public.ensure_agent_for_manager(NEW.id);
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_profiles_ensure_agent()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NEW.role = 'manager' THEN
    IF NEW.enterprise_id IS DISTINCT FROM OLD.enterprise_id THEN
      UPDATE public.health_manager_agents
         SET is_active = false, updated_at = now()
       WHERE manager_id = NEW.id AND is_active = true
         AND enterprise_id IS DISTINCT FROM NEW.enterprise_id;
      UPDATE public.health_manager_agents
         SET enterprise_id = NEW.enterprise_id, updated_at = now()
       WHERE manager_id = NEW.id AND status = 'draft'
         AND enterprise_id IS DISTINCT FROM NEW.enterprise_id;
    END IF;
    PERFORM public.ensure_agent_for_manager(NEW.id);
  ELSIF NEW.role <> 'manager' THEN
    UPDATE public.health_manager_agents
       SET is_active = false, updated_at = now()
     WHERE manager_id = NEW.id AND is_active = true;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.publish_manager_agent(p_agent_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ent uuid;
  v_agent public.health_manager_agents%ROWTYPE;
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

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = v_agent.manager_id AND p.enterprise_id = v_ent AND p.role = 'manager'
  ) THEN
    RETURN json_build_object('error', '该健管师已不属于本企业');
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