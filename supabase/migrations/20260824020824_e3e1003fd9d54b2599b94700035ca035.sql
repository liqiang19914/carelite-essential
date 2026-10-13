-- ── 我的对话列表：平台主端只看平台对话（owner 为空），OEM 只看本店对话 ──
DROP FUNCTION IF EXISTS public.get_my_conversations(uuid, text, integer);

CREATE OR REPLACE FUNCTION public.get_my_conversations(p_shop_root uuid DEFAULT NULL::uuid, p_agent_slug text DEFAULT NULL::text, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid   uuid := auth.uid();
  v_root  uuid;
  v_out   jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

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
          AND c.owner_manager_id IS NULL
        OR v_root IS NOT NULL
          AND c.owner_manager_id IS NOT NULL
          AND public.get_enterprise_root_manager_id(c.owner_manager_id) = v_root
      )
      AND (p_agent_slug IS NULL OR a.slug = p_agent_slug)
    ORDER BY c.updated_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100)
  ) t;

  RETURN v_out;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_my_conversations(uuid, text, integer) TO authenticated, anon, service_role;

-- ── 我的对话计数：同语义 ──
DROP FUNCTION IF EXISTS public.get_my_conversation_count(uuid);

CREATE OR REPLACE FUNCTION public.get_my_conversation_count(p_shop_root uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
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
        AND c.owner_manager_id IS NULL
      OR v_root IS NOT NULL
        AND c.owner_manager_id IS NOT NULL
        AND public.get_enterprise_root_manager_id(c.owner_manager_id) = v_root
    );

  RETURN v_count;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_my_conversation_count(uuid) TO authenticated, anon, service_role;

-- ── 我的对话消息：会话归属 + 作用域校验后返回 ──
CREATE OR REPLACE FUNCTION public.get_my_conversation_messages(p_conversation_id uuid, p_shop_root uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_conv public.conversations;
  v_out jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_conv FROM public.conversations c
  WHERE c.id = p_conversation_id AND c.user_id = v_uid;

  IF v_conv.id IS NULL THEN
    RAISE EXCEPTION '对话不存在' USING ERRCODE = '22023';
  END IF;

  IF p_shop_root IS NOT NULL THEN
    v_root := public.get_enterprise_root_manager_id(p_shop_root);
  END IF;

  IF NOT (
    (v_root IS NULL AND v_conv.owner_manager_id IS NULL)
    OR
    (v_root IS NOT NULL AND v_conv.owner_manager_id IS NOT NULL
     AND public.get_enterprise_root_manager_id(v_conv.owner_manager_id) = v_root)
  ) THEN
    RAISE EXCEPTION '对话不存在' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(jsonb_agg(t.row_json ORDER BY t.created_at ASC), '[]'::jsonb) INTO v_out
  FROM (
    SELECT to_jsonb(m) AS row_json
    FROM public.messages m
    WHERE m.conversation_id = p_conversation_id
    ORDER BY m.created_at ASC
    LIMIT 200
  ) t;

  RETURN v_out;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_my_conversation_messages(uuid, uuid) TO authenticated, anon, service_role;