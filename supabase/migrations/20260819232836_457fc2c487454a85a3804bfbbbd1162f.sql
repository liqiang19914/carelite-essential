-- 代码审查修复：对话按店过滤在「传了店但解析不出来」时必须回空，不能退回平台全量

CREATE OR REPLACE FUNCTION public.get_my_conversations(
  p_shop_root uuid DEFAULT NULL,
  p_agent_slug text DEFAULT NULL,
  p_limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid   uuid := auth.uid();
  v_root  uuid;
  v_out   jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  -- 明确传 NULL = 平台主端（看本人全部）；传了值但解析不出企业根 = 无效店铺，回空
  IF p_shop_root IS NOT NULL THEN
    v_root := public.get_enterprise_root_manager_id(p_shop_root);
    IF v_root IS NULL THEN
      RETURN '[]'::jsonb;
    END IF;
  END IF;

  SELECT COALESCE(jsonb_agg(t.row_json ORDER BY t.updated_at DESC), '[]'::jsonb) INTO v_out
  FROM (
    SELECT
      c.updated_at,
      to_jsonb(c) || jsonb_build_object(
        'agent_name', a.name,
        'agent_icon', a.icon,
        'agent_slug', a.slug
      ) AS row_json
    FROM public.conversations c
    LEFT JOIN public.ai_agents a ON a.id = c.agent_id
    WHERE c.user_id = v_uid
      AND (
        v_root IS NULL
        OR (c.owner_manager_id IS NOT NULL
            AND public.get_enterprise_root_manager_id(c.owner_manager_id) = v_root)
      )
      AND (p_agent_slug IS NULL OR a.slug = p_agent_slug)
    ORDER BY c.updated_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100)
  ) t;

  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_my_conversations(uuid, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_conversations(uuid, text, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_my_conversation_count(
  p_shop_root uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid   uuid := auth.uid();
  v_root  uuid;
  v_count integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  IF p_shop_root IS NOT NULL THEN
    v_root := public.get_enterprise_root_manager_id(p_shop_root);
    IF v_root IS NULL THEN
      RETURN 0;
    END IF;
  END IF;

  SELECT count(*) INTO v_count
  FROM public.conversations c
  WHERE c.user_id = v_uid
    AND (
      v_root IS NULL
      OR (c.owner_manager_id IS NOT NULL
          AND public.get_enterprise_root_manager_id(c.owner_manager_id) = v_root)
    );

  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_my_conversation_count(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_conversation_count(uuid) TO authenticated;