-- 绑定红线：健管师跟着公司走。在企业 App 内绑定只允许本企业健管师。
-- 三个绑定 RPC 统一新增可选参数 p_root_manager_id（企业根，前端壳内传 brand.managerId，
-- 平台/公开场景传 null 不校验）。先 DROP 旧签名再建新签名，避免重载歧义；DROP 后重发 GRANT。

DROP FUNCTION IF EXISTS public.bind_manager_by_invite_code(text);
DROP FUNCTION IF EXISTS public.bind_manager_from_card(uuid, text);
DROP FUNCTION IF EXISTS public.bind_manager_from_public(uuid);

CREATE OR REPLACE FUNCTION public.bind_manager_by_invite_code(p_invite_code text, p_root_manager_id uuid DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_uid UUID;
  v_manager managers%ROWTYPE;
  v_relation_id UUID;
  v_normalized TEXT;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF p_invite_code IS NULL OR length(trim(p_invite_code)) = 0 THEN
    RAISE EXCEPTION '请输入邀请码' USING ERRCODE = '22023';
  END IF;

  v_normalized := trim(p_invite_code);

  SELECT * INTO v_manager
    FROM managers
   WHERE invite_code = v_normalized
     AND COALESCE(is_example, false) = false
   LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION '邀请码无效' USING ERRCODE = 'P0002';
  END IF;

  IF p_root_manager_id IS NOT NULL THEN
    IF COALESCE(
         (SELECT parent_manager_id FROM public.profiles WHERE id = p_root_manager_id),
         p_root_manager_id
       ) IS DISTINCT FROM COALESCE(
         (SELECT parent_manager_id FROM public.profiles WHERE id = v_manager.id),
         v_manager.id
       ) THEN
      RAISE EXCEPTION '该健康管理师不属于当前企业，请返回本企业健康管理师列表重新选择' USING ERRCODE = '22023';
    END IF;
  END IF;

  SELECT id INTO v_relation_id
  FROM client_relations
  WHERE client_id = v_uid AND manager_id = v_manager.id;

  IF v_relation_id IS NULL THEN
    INSERT INTO client_relations (manager_id, client_id, status, last_contact_at)
    VALUES (v_manager.id, v_uid, 'active', NOW())
    RETURNING id INTO v_relation_id;
  ELSE
    UPDATE client_relations
       SET status = 'active', updated_at = NOW(), last_contact_at = NOW()
     WHERE id = v_relation_id;
  END IF;

  RETURN json_build_object('success', true, 'manager_id', v_manager.id, 'relation_id', v_relation_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.bind_manager_by_invite_code(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bind_manager_by_invite_code(text, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.bind_manager_from_card(p_manager_id uuid, p_invite_code text, p_root_manager_id uuid DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_uid UUID;
  v_manager managers%ROWTYPE;
  v_relation_id UUID;
  v_normalized TEXT;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  IF p_manager_id IS NULL THEN
    RAISE EXCEPTION '健康管理师不存在' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_manager FROM managers WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '健康管理师不存在' USING ERRCODE = 'P0002';
  END IF;

  IF COALESCE(v_manager.is_example, false) THEN
    RAISE EXCEPTION '示例管理师不可绑定，请使用真实管理师的邀请码' USING ERRCODE = '22023';
  END IF;

  IF p_invite_code IS NULL OR length(trim(p_invite_code)) = 0 THEN
    RAISE EXCEPTION '请输入邀请码' USING ERRCODE = '22023';
  END IF;

  v_normalized := trim(p_invite_code);
  IF v_manager.invite_code IS NULL OR v_manager.invite_code <> v_normalized THEN
    RAISE EXCEPTION '邀请码错误' USING ERRCODE = '22023';
  END IF;

  IF p_root_manager_id IS NOT NULL THEN
    IF COALESCE(
         (SELECT parent_manager_id FROM public.profiles WHERE id = p_root_manager_id),
         p_root_manager_id
       ) IS DISTINCT FROM COALESCE(
         (SELECT parent_manager_id FROM public.profiles WHERE id = v_manager.id),
         v_manager.id
       ) THEN
      RAISE EXCEPTION '该健康管理师不属于当前企业，请返回本企业健康管理师列表重新选择' USING ERRCODE = '22023';
    END IF;
  END IF;

  SELECT id INTO v_relation_id
  FROM client_relations
  WHERE client_id = v_uid AND manager_id = p_manager_id;

  IF v_relation_id IS NULL THEN
    INSERT INTO client_relations (manager_id, client_id, status, last_contact_at)
    VALUES (p_manager_id, v_uid, 'active', NOW())
    RETURNING id INTO v_relation_id;
  ELSE
    UPDATE client_relations
       SET status = 'active', updated_at = NOW(), last_contact_at = NOW()
     WHERE id = v_relation_id;
  END IF;

  RETURN json_build_object('success', true, 'manager_id', p_manager_id, 'relation_id', v_relation_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.bind_manager_from_card(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bind_manager_from_card(uuid, text, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.bind_manager_from_public(p_manager_id uuid, p_root_manager_id uuid DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_manager public.managers%ROWTYPE;
  v_role text;
  v_relation_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;
  IF p_manager_id IS NULL THEN
    RAISE EXCEPTION '健康管理师不存在' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_manager FROM public.managers WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '健康管理师不存在' USING ERRCODE = 'P0002';
  END IF;

  SELECT role::text INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role IS DISTINCT FROM 'user' THEN
    RETURN json_build_object('success', false, 'reason', 'role_not_user', 'manager_id', p_manager_id);
  END IF;

  IF COALESCE(v_manager.is_example, false) THEN
    RETURN json_build_object('success', false, 'reason', 'example_manager', 'manager_id', p_manager_id);
  END IF;

  IF v_manager.certification_status IS DISTINCT FROM 'approved' THEN
    RETURN json_build_object('success', false, 'reason', 'manager_not_approved', 'manager_id', p_manager_id);
  END IF;

  IF p_root_manager_id IS NOT NULL THEN
    IF COALESCE(
         (SELECT parent_manager_id FROM public.profiles WHERE id = p_root_manager_id),
         p_root_manager_id
       ) IS DISTINCT FROM COALESCE(
         (SELECT parent_manager_id FROM public.profiles WHERE id = v_manager.id),
         v_manager.id
       ) THEN
      RAISE EXCEPTION '该健康管理师不属于当前企业，请返回本企业健康管理师列表重新选择' USING ERRCODE = '22023';
    END IF;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text, 11));

  SELECT id INTO v_relation_id
  FROM public.client_relations
  WHERE client_id = v_uid AND manager_id = p_manager_id;

  IF v_relation_id IS NULL THEN
    INSERT INTO public.client_relations (manager_id, client_id, status, last_contact_at)
    VALUES (p_manager_id, v_uid, 'active', NOW())
    RETURNING id INTO v_relation_id;
  ELSE
    UPDATE public.client_relations
       SET status = 'active', updated_at = NOW(), last_contact_at = NOW()
     WHERE id = v_relation_id;
  END IF;

  RETURN json_build_object('success', true, 'reason', 'bound', 'manager_id', p_manager_id, 'relation_id', v_relation_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.bind_manager_from_public(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bind_manager_from_public(uuid, uuid) TO authenticated;

-- 企业健管师公开列表补「擅长」简介字段
CREATE OR REPLACE FUNCTION public.list_public_enterprise_managers(p_manager_id uuid)
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
    RETURN '[]'::json;
  END IF;

  SELECT COALESCE(p.parent_manager_id, p.id) INTO v_root
  FROM public.profiles p
  WHERE p.id = p_manager_id;

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
    AND COALESCE(m.is_example, false) = false;

  RETURN COALESCE(v_result, '[]'::json);
END;
$function$;