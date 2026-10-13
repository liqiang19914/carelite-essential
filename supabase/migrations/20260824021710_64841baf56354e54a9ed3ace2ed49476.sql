-- ── 我的会话详情：归属 + 作用域校验后返回会话与智能体信息 ──
CREATE OR REPLACE FUNCTION public.get_my_conversation_detail(p_conversation_id uuid, p_shop_root uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid  uuid := auth.uid();
  v_root uuid;
  v_conv public.conversations;
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

  RETURN (
    SELECT to_jsonb(c) || jsonb_build_object(
      'ai_agents', (
        SELECT to_jsonb(a) FROM public.ai_agents a WHERE a.id = c.agent_id
      )
    )
    FROM public.conversations c
    WHERE c.id = v_conv.id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_my_conversation_detail(uuid, uuid) TO authenticated, anon, service_role;