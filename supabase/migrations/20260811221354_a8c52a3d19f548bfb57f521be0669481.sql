-- 客户可以同时属于多家商户：绑定新商户时不再自动停掉原有归属。
-- 原来是「一人一时只能属于一家」，与 100 家 OEM 商户共存的模型直接冲突：
-- 客户在 A 的小程序里绑过，再打开 B 就会把 A 的归属停掉，A 那边客户凭空消失。
CREATE OR REPLACE FUNCTION public.bind_manager_by_invite_code(p_invite_code text)
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

CREATE OR REPLACE FUNCTION public.bind_manager_from_card(p_manager_id uuid, p_invite_code text)
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

CREATE OR REPLACE FUNCTION public.bind_manager_from_public(p_manager_id uuid)
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