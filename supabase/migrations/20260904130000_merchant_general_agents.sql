-- 商户端通用智能体设置：开关、改名、覆盖 system prompt、排序
-- 预置 6 个智能体（平台端 agents 表 slug 对应），商户可独立配置

CREATE TABLE IF NOT EXISTS public.merchant_general_agents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  agent_slug text NOT NULL,
  display_name text NOT NULL,
  icon_url text,
  enabled boolean NOT NULL DEFAULT true,
  custom_system_prompt text,
  sort_order int NOT NULL DEFAULT 100,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_merchant_general_agent UNIQUE (root_manager_id, agent_slug)
);

CREATE INDEX IF NOT EXISTS idx_merchant_general_agents_root
  ON public.merchant_general_agents (root_manager_id, sort_order);

ALTER TABLE public.merchant_general_agents ENABLE ROW LEVEL SECURITY;
-- 不加细粒度 POLICY：全部通过 SECURITY DEFINER RPC 按 root_manager_id 校验

-- RPC：读取（SECURITY DEFINER，前端直接调用）
CREATE OR REPLACE FUNCTION public.list_merchant_general_agents()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_rows jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_merchant_root(auth.uid()) THEN
    RETURN jsonb_build_object('items', jsonb_build_array());
  END IF;
  v_root := auth.uid();

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', t.id,
        'agentSlug', t.agent_slug,
        'displayName', t.display_name,
        'iconUrl', t.icon_url,
        'enabled', t.enabled,
        'customSystemPrompt', t.custom_system_prompt,
        'sortOrder', t.sort_order
      ) ORDER BY t.sort_order
    ),
    jsonb_build_array()
  ) INTO v_rows
  FROM public.merchant_general_agents t
  WHERE t.root_manager_id = v_root;

  RETURN jsonb_build_object('items', v_rows);
END;
$function$;

-- RPC：保存（upsert 单条或批量）
CREATE OR REPLACE FUNCTION public.save_merchant_general_agent_configs(p_configs jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_cfg jsonb;
  v_items jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_merchant_root(auth.uid()) THEN
    RETURN jsonb_build_object('ok', false, 'error', '无权限');
  END IF;
  v_root := auth.uid();

  IF jsonb_typeof(p_configs) = 'array' THEN
    v_items := p_configs;
  ELSIF jsonb_typeof(p_configs) = 'object' THEN
    v_items := jsonb_build_array(p_configs);
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', '参数格式错误');
  END IF;

  FOR v_cfg IN SELECT * FROM jsonb_array_elements(v_items)
  LOOP
    INSERT INTO public.merchant_general_agents
      (root_manager_id, agent_slug, display_name, icon_url, enabled, custom_system_prompt, sort_order)
    VALUES
      (
        v_root,
        (v_cfg->>'agentSlug'),
        COALESCE(v_cfg->>'displayName', v_cfg->>'agentSlug'),
        v_cfg->>'iconUrl',
        COALESCE((v_cfg->>'enabled')::boolean, true),
        v_cfg->>'customSystemPrompt',
        COALESCE((v_cfg->>'sortOrder')::int, 100)
      )
    ON CONFLICT (root_manager_id, agent_slug) DO UPDATE SET
      display_name = EXCLUDED.display_name,
      icon_url = EXCLUDED.icon_url,
      enabled = EXCLUDED.enabled,
      custom_system_prompt = EXCLUDED.custom_system_prompt,
      sort_order = EXCLUDED.sort_order,
      updated_at = now();
  END LOOP;

  RETURN jsonb_build_object('ok', true);
END;
$function$;
