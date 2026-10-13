CREATE OR REPLACE FUNCTION public.ensure_my_diet_map_template()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_ref public.diet_map_templates%ROWTYPE;
  v_own_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;

  IF NOT public.is_enterprise_admin(v_uid) THEN
    RAISE EXCEPTION '只有企业主或企业管理员可以配置饮食导图' USING ERRCODE = '42501';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号还没有归属企业，无法配置饮食导图' USING ERRCODE = '42501';
  END IF;

  -- 授权始终指向平台参考版
  SELECT t.* INTO v_ref
    FROM public.diet_map_templates t
    JOIN public.diet_map_grants g ON g.template_id = t.id
   WHERE g.root_manager_id = v_root
     AND g.is_enabled = true
     AND t.root_manager_id IS NULL
   ORDER BY g.granted_at DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('granted', false, 'root_manager_id', v_root);
  END IF;

  SELECT t.id INTO v_own_id
    FROM public.diet_map_templates t
   WHERE t.root_manager_id = v_root
     AND t.source_template_id = v_ref.id;

  IF v_own_id IS NULL THEN
    -- 副本必须连同「分值已确认」一起继承：内容与参考版逐字一致，
    -- 重置成未确认会让商户一发布就把全店客户打回「待评定」、看不到任何饮食建议。
    -- status 仍然只能是 draft —— 没发布之前客户读的是平台参考版。
    INSERT INTO public.diet_map_templates (
      map_key, title, description, status,
      questions, scoring, report,
      config_version, scoring_confirmed, scoring_confirmed_by, scoring_confirmed_at,
      root_manager_id, source_template_id, created_by
    ) VALUES (
      v_ref.map_key, v_ref.title, v_ref.description, 'draft',
      v_ref.questions, v_ref.scoring, v_ref.report,
      1, v_ref.scoring_confirmed, v_ref.scoring_confirmed_by, v_ref.scoring_confirmed_at,
      v_root, v_ref.id, v_uid
    )
    RETURNING id INTO v_own_id;
  END IF;

  RETURN jsonb_build_object(
    'granted', true,
    'root_manager_id', v_root,
    'template_id', v_own_id,
    'reference_template_id', v_ref.id
  );
END;
$function$;