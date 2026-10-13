-- 兼容修正：PG16 起 jsonb_set 不会自动补缺失的中间容器，且 new_value 为 SQL NULL 会整体置空。
-- 改用 jsonb || 深合并 + jsonb_build_object 的写法，缺中间容器也会正确创建。
CREATE OR REPLACE FUNCTION public.get_my_diet_map_access(p_mp_manager uuid DEFAULT NULL::uuid, p_record_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_manager uuid;
  v_trusted boolean := false;
  v_ref public.diet_map_templates%ROWTYPE;
  v_tpl public.diet_map_templates%ROWTYPE;
  v_source text := 'reference';
  v_record uuid;
  v_latest jsonb := NULL;
  v_code text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再查看健康饮食导图' USING ERRCODE = '28000';
  END IF;

  IF p_mp_manager IS NOT NULL THEN
    v_root := public.get_enterprise_root_manager_id(p_mp_manager);
  END IF;

  IF v_root IS NOT NULL THEN
    SELECT cr.manager_id INTO v_manager
      FROM public.client_relations cr
      JOIN public.profiles mp ON mp.id = cr.manager_id
     WHERE cr.client_id = v_uid
       AND cr.status = 'active'
       AND mp.role = 'manager'
       AND COALESCE(mp.parent_manager_id, mp.id) = v_root
     ORDER BY (cr.manager_id = p_mp_manager) DESC, cr.created_at DESC, cr.id DESC
     LIMIT 1;
  ELSE
    SELECT cr.manager_id, COALESCE(mp.parent_manager_id, mp.id)
      INTO v_manager, v_root
      FROM public.client_relations cr
      JOIN public.profiles mp ON mp.id = cr.manager_id
     WHERE cr.client_id = v_uid
       AND cr.status = 'active'
       AND mp.role = 'manager'
     ORDER BY cr.created_at DESC, cr.id DESC
     LIMIT 1;
  END IF;

  IF v_root IS NULL THEN
    RETURN jsonb_build_object('open', false, 'reason', 'no_merchant');
  END IF;

  v_trusted := v_manager IS NOT NULL
    OR EXISTS (
      SELECT 1 FROM public.manager_miniprograms mm
       WHERE mm.manager_id = v_root AND mm.is_enabled = true
    );

  IF NOT v_trusted THEN
    RETURN jsonb_build_object('open', false, 'reason', 'no_merchant');
  END IF;

  -- 授权始终挂在平台参考版上
  SELECT t.* INTO v_ref
    FROM public.diet_map_templates t
    JOIN public.diet_map_grants g ON g.template_id = t.id
   WHERE g.root_manager_id = v_root
     AND g.is_enabled = true
     AND t.root_manager_id IS NULL
   ORDER BY g.granted_at DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('open', false, 'reason', 'not_granted', 'root_manager_id', v_root);
  END IF;

  -- 商户自己已发布的版本优先
  SELECT t.* INTO v_tpl
    FROM public.diet_map_templates t
   WHERE t.root_manager_id = v_root
     AND t.source_template_id = v_ref.id
     AND t.status = 'published'
   LIMIT 1;

  IF FOUND THEN
    v_source := 'merchant';
  ELSE
    IF v_ref.status <> 'published' THEN
      RETURN jsonb_build_object('open', false, 'reason', 'not_granted', 'root_manager_id', v_root);
    END IF;
    v_tpl := v_ref;
    v_source := 'reference';
  END IF;

  -- 商户版报告合并：每个型的饮食指南长图（含存储键）、对外中文名、解析文案，
  -- 商户留空即回退平台参考版；其余内容尊重商户自己的编辑。
  IF v_source = 'merchant' THEN
    FOREACH v_code IN ARRAY ARRAY['S','A','C','N','D','G'] LOOP
      IF NULLIF(btrim(v_tpl.report #>> ARRAY['types', v_code, 'dietGuideImageUrl']), '') IS NULL
         AND NULLIF(btrim(v_ref.report #>> ARRAY['types', v_code, 'dietGuideImageUrl']), '') IS NOT NULL THEN
        v_tpl.report := v_tpl.report || jsonb_build_object(
          'types', jsonb_build_object(
            v_code, jsonb_build_object(
              'dietGuideImageUrl', v_ref.report #>> ARRAY['types', v_code, 'dietGuideImageUrl'],
              'dietGuideImageStorageKey', COALESCE(v_ref.report #>> ARRAY['types', v_code, 'dietGuideImageStorageKey'], '')
            )
          )
        );
      END IF;
      IF NULLIF(btrim(v_tpl.report #>> ARRAY['types', v_code, 'name']), '') IS NULL
         AND NULLIF(btrim(v_ref.report #>> ARRAY['types', v_code, 'name']), '') IS NOT NULL THEN
        v_tpl.report := v_tpl.report || jsonb_build_object(
          'types', jsonb_build_object(
            v_code, jsonb_build_object('name', v_ref.report #>> ARRAY['types', v_code, 'name'])
          )
        );
      END IF;
      IF NULLIF(btrim(v_tpl.report #>> ARRAY['types', v_code, 'analysis']), '') IS NULL
         AND NULLIF(btrim(v_ref.report #>> ARRAY['types', v_code, 'analysis']), '') IS NOT NULL THEN
        v_tpl.report := v_tpl.report || jsonb_build_object(
          'types', jsonb_build_object(
            v_code, jsonb_build_object('analysis', v_ref.report #>> ARRAY['types', v_code, 'analysis'])
          )
        );
      END IF;
    END LOOP;
  END IF;

  IF p_record_id IS NOT NULL THEN
    SELECT hr.id INTO v_record
      FROM public.health_records hr
     WHERE hr.id = p_record_id AND hr.user_id = v_uid;
  END IF;

  IF v_record IS NULL THEN
    SELECT hr.id INTO v_record
      FROM public.health_records hr
     WHERE hr.user_id = v_uid
     ORDER BY hr.is_default DESC, hr.created_at
     LIMIT 1;
  END IF;

  -- 历史按企业隔离：同一份档案在别家商户答过的记录不会串过来。
  -- 模板可能刚从参考版切到商户版，所以不按 template_id 而按企业根取最近一条。
  IF v_record IS NOT NULL THEN
    SELECT jsonb_build_object(
             'id', a.id,
             'status', a.status,
             'type_code', a.type_code,
             'submitted_at', a.submitted_at,
             'record_id', a.record_id,
             'config_version', a.config_version
           )
      INTO v_latest
      FROM public.diet_map_assessments a
     WHERE a.record_id = v_record
       AND COALESCE(a.root_manager_id, v_root) = v_root
     ORDER BY a.submitted_at DESC, a.id DESC
     LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'open', true,
    'root_manager_id', v_root,
    'manager_id', v_manager,
    'record_id', v_record,
    'template_source', v_source,
    'template', jsonb_build_object(
      'id', v_tpl.id,
      'map_key', v_tpl.map_key,
      'title', v_tpl.title,
      'description', v_tpl.description,
      'config_version', v_tpl.config_version,
      'scoring_confirmed', v_tpl.scoring_confirmed,
      'questions', v_tpl.questions,
      'report', v_tpl.report
    ),
    'latest', v_latest
  );
END;
$function$;

-- 回退信息接口同样改 jsonb || 深合并写法。
CREATE OR REPLACE FUNCTION public.get_diet_map_reference_fallback(p_template_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_tpl public.diet_map_templates%ROWTYPE;
  v_ref public.diet_map_templates%ROWTYPE;
  v_code text;
  v_out jsonb := '{}'::jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.diet_map_can_manage_template(p_template_id, v_uid) THEN
    RAISE EXCEPTION '没有权限查看这份模板的回退信息' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_tpl FROM public.diet_map_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '没有找到这份模板' USING ERRCODE = 'PGRST116';
  END IF;

  IF v_tpl.root_manager_id IS NULL THEN
    RETURN jsonb_build_object('is_reference', true, 'types', '{}'::jsonb);
  END IF;

  SELECT * INTO v_ref FROM public.diet_map_templates WHERE id = v_tpl.source_template_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('is_reference', false, 'types', '{}'::jsonb);
  END IF;

  FOREACH v_code IN ARRAY ARRAY['S','A','C','N','D','G'] LOOP
    v_out := v_out || jsonb_build_object(
      'types', jsonb_build_object(
        v_code, jsonb_build_object(
          'dietGuideImageUrl', COALESCE(v_ref.report #>> ARRAY['types', v_code, 'dietGuideImageUrl'], ''),
          'name', COALESCE(v_ref.report #>> ARRAY['types', v_code, 'name'], '')
        )
      )
    );
  END LOOP;

  RETURN jsonb_build_object('is_reference', false, 'types', v_out -> 'types');
END;
$function$;

REVOKE ALL ON FUNCTION public.get_diet_map_reference_fallback(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_diet_map_reference_fallback(uuid) TO authenticated;