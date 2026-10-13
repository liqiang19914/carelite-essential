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
    WHERE a.manager_id = p_manager_id AND a.is_active = true
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

UPDATE public.health_manager_agents a
SET name = p.nickname
FROM public.profiles p
WHERE a.manager_id = p.id
  AND a.is_active = true
  AND a.name = '健康管理师'
  AND p.role = 'manager'
  AND NULLIF(trim(p.nickname), '') IS NOT NULL;