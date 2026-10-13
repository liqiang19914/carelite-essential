-- 只改错误文案的精确度：授权已开通、但题库还在草稿时，
-- 原文案「本店尚未开放健康饮食导图」会和商户端已经能看到客户名单的事实自相矛盾，
-- 商户会以为自己没被开通。拆成两种原因分别说明。
CREATE OR REPLACE FUNCTION public.send_diet_map_invite(
  p_client_user_ids uuid[],
  p_template_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_client uuid;
  v_ids uuid[];
  v_title text;
  v_granted boolean;
  v_notify boolean;
  v_sent int := 0;
  v_skipped int := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '仅健康管理师可发送邀请' USING ERRCODE = '42501';
  END IF;

  SELECT t.title INTO v_title
    FROM public.diet_map_templates t
    JOIN public.diet_map_grants g ON g.template_id = t.id
   WHERE g.root_manager_id = v_root
     AND g.is_enabled = true
     AND t.status = 'published'
     AND (p_template_id IS NULL OR t.id = p_template_id)
   ORDER BY g.granted_at DESC
   LIMIT 1;

  IF v_title IS NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.diet_map_grants g
       WHERE g.root_manager_id = v_root
         AND g.is_enabled = true
         AND (p_template_id IS NULL OR g.template_id = p_template_id)
    ) INTO v_granted;

    IF v_granted THEN
      RAISE EXCEPTION '这份健康饮食导图还没有正式发布，等平台发布后就能邀请客户了'
        USING ERRCODE = '42501';
    END IF;

    RAISE EXCEPTION '本店尚未开放健康饮食导图，无法发送邀请' USING ERRCODE = '42501';
  END IF;

  IF p_client_user_ids IS NULL OR COALESCE(array_length(p_client_user_ids, 1), 0) = 0 THEN
    RAISE EXCEPTION '请先选择至少一位客户' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(array_length(p_client_user_ids, 1), 0) > 100 THEN
    RAISE EXCEPTION '单次最多可邀请 100 位客户' USING ERRCODE = '22023';
  END IF;

  SELECT ARRAY(SELECT DISTINCT x FROM unnest(p_client_user_ids) x WHERE x IS NOT NULL)
    INTO v_ids;

  FOREACH v_client IN ARRAY v_ids LOOP
    IF NOT public.diet_map_is_my_client(v_client, v_uid) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    SELECT COALESCE((notification_settings ->> 'health')::boolean, true)
      INTO v_notify
      FROM public.profiles WHERE id = v_client;

    IF v_notify IS NOT TRUE THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_client,
      'diet_map_invite',
      '邀请你生成健康饮食导图',
      COALESCE(NULLIF(btrim(v_title), ''), '健康饮食导图') || '：花几分钟完成自测，就能生成属于你的饮食导图。',
      jsonb_build_object('template_id', p_template_id, 'from_manager_id', v_uid)
    );
    v_sent := v_sent + 1;
  END LOOP;

  RETURN jsonb_build_object('sent', v_sent, 'skipped', v_skipped);
END;
$function$;

REVOKE ALL ON FUNCTION public.send_diet_map_invite(uuid[], uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.send_diet_map_invite(uuid[], uuid) TO authenticated;