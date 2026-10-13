-- Public demo may show complete agent settings, but only for the three synthetic enterprises.
ALTER FUNCTION public.get_public_readonly_demo(text)
  RENAME TO get_public_readonly_demo_base_20260916;

REVOKE ALL ON FUNCTION public.get_public_readonly_demo_base_20260916(text)
  FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.get_public_readonly_demo(p_theme text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_root uuid;
  v_enterprise uuid;
  v_data jsonb;
BEGIN
  v_data := public.get_public_readonly_demo_base_20260916(p_theme);
  IF v_data IS NULL THEN RETURN NULL; END IF;

  v_root := CASE p_theme
    WHEN 'weight' THEN '9d20bc6b-cbd4-4153-84e5-01e5b58f041f'::uuid
    WHEN 'nutrition' THEN 'c6cc187c-3b13-40fc-befb-aa70594ebe3c'::uuid
    WHEN 'chronic' THEN 'bfb89a01-4c1c-43fc-bce0-fe18e0401b4e'::uuid
  END;

  SELECT enterprise_id INTO v_enterprise
  FROM public.managers
  WHERE id = v_root AND is_example = true;

  RETURN v_data || jsonb_build_object(
    'agents', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'name', COALESCE(NULLIF(a.name, ''), a.config->>'business_name', '健康管理智能体'),
        'tagline', a.config->>'tagline',
        'intro', a.config->>'intro_personal',
        'credentials', COALESCE(a.config->'credentials', '[]'::jsonb),
        'system_prompt', a.config->>'knowledge_system_prompt',
        'welcome_message', a.config->>'public_qa_welcome_message',
        'model', a.config->>'knowledge_model'
      ) ORDER BY (a.manager_id = v_root) DESC, a.name)
      FROM public.health_manager_agents a
      WHERE a.enterprise_id = v_enterprise AND a.is_active = true AND a.status = 'published'
        AND (
          (p_theme = 'weight' AND a.manager_id IN (
            v_root,
            '97be8cc0-45cc-420f-ba8f-5df7a2b02f4f'::uuid,
            'aaf34d8b-4746-476c-aef1-9d27ac31975f'::uuid,
            '1d6fe4ae-33e0-4a24-b41f-d8dbfe29ed2a'::uuid,
            '3c5eca26-eb14-4318-897c-d4dcfc5b6e77'::uuid
          ))
          OR (p_theme IN ('nutrition', 'chronic') AND EXISTS (
            SELECT 1 FROM public.managers m
            WHERE m.id = a.manager_id AND m.is_example = true
              AND (m.id = v_root OR m.system_default_key IN ('chronic', 'gut', 'weight', 'sleep', 'fitness'))
          ))
        )
    ), '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_public_readonly_demo(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_readonly_demo(text) TO anon, authenticated;

DO $$
DECLARE v jsonb;
BEGIN
  v := public.get_public_readonly_demo('weight');
  IF jsonb_array_length(v->'agents') <> 5
     OR (v->'agents'->0) ?| ARRAY['phone','email','password','manager_id'] THEN
    RAISE EXCEPTION 'public demo agent projection check failed';
  END IF;
END;
$$;
