-- ④ 商户首次进入配置页：把已获授权的平台参考版复制成本企业草稿（幂等）。
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
    INSERT INTO public.diet_map_templates (
      map_key, title, description, status,
      questions, scoring, report,
      config_version, scoring_confirmed,
      root_manager_id, source_template_id, created_by
    ) VALUES (
      v_ref.map_key, v_ref.title, v_ref.description, 'draft',
      v_ref.questions, v_ref.scoring, v_ref.report,
      1, false,
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

REVOKE ALL ON FUNCTION public.ensure_my_diet_map_template() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ensure_my_diet_map_template() TO authenticated, service_role;

-- ⑤ 平台端查看各商户的版本记录（只读概览，不暴露题目内容）。
CREATE OR REPLACE FUNCTION public.list_diet_map_merchant_versions(p_reference_template_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_rows jsonb;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅平台管理员可查看各商户的饮食导图版本' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.updated_at DESC), '[]'::jsonb)
    INTO v_rows
    FROM (
      SELECT
        t.id AS template_id,
        t.root_manager_id,
        COALESCE(NULLIF(btrim(mp.nickname), ''), '未命名商户') AS merchant_name,
        t.status,
        t.config_version,
        t.scoring_confirmed,
        t.title,
        t.updated_at,
        (SELECT count(*) FROM public.diet_map_assessments a
          WHERE a.root_manager_id = t.root_manager_id) AS assessment_count
      FROM public.diet_map_templates t
      LEFT JOIN public.profiles mp ON mp.id = t.root_manager_id
     WHERE t.root_manager_id IS NOT NULL
       AND (p_reference_template_id IS NULL OR t.source_template_id = p_reference_template_id)
     LIMIT 200
    ) r;

  RETURN jsonb_build_object('versions', v_rows);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_diet_map_merchant_versions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_diet_map_merchant_versions(uuid) TO authenticated, service_role;