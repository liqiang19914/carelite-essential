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
  v_report jsonb;
  v_types text[] := ARRAY['S','D','G','N','C','A'];
  v_merge_fields text[] := ARRAY['name','analysis','dietGuideImageUrl','dietGuideImageStorageKey'];
  v_t text;
  v_f text;
  v_m_val jsonb;
  v_r_val jsonb;
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

  -- 商户自己「已发布且评分已确认」的版本才优先；未确认的发布不能顶掉平台版
  SELECT t.* INTO v_tpl
    FROM public.diet_map_templates t
   WHERE t.root_manager_id = v_root
     AND t.source_template_id = v_ref.id
     AND t.status = 'published'
     AND t.scoring_confirmed = true
   LIMIT 1;

  IF FOUND THEN
    v_source := 'merchant';
  ELSE
    IF v_ref.status <> 'published' OR NOT COALESCE(v_ref.scoring_confirmed, false) THEN
      RETURN jsonb_build_object('open', false, 'reason', 'not_granted', 'root_manager_id', v_root);
    END IF;
    v_tpl := v_ref;
    v_source := 'reference';
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
  IF v_record IS NOT NULL THEN
    SELECT jsonb_build_object(
             'id', a.id,
             'status', a.status,
             'type_code', a.type_code,
             'verdict', a.verdict,
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

  -- 报告合并：商户版缺失的对外名称/解析/指南图按平台参考版回退（不覆盖商户已有内容）
  v_report := v_tpl.report;
  IF v_source = 'merchant' AND v_ref.id IS NOT NULL THEN
    FOREACH v_t IN ARRAY v_types LOOP
      FOREACH v_f IN ARRAY v_merge_fields LOOP
        v_m_val := v_report -> 'types' -> v_t -> v_f;
        IF v_m_val IS NULL OR jsonb_typeof(v_m_val) = 'null'
           OR NULLIF(btrim(COALESCE(v_m_val #>> '{}', '')), '') IS NULL THEN
          v_r_val := v_ref.report -> 'types' -> v_t -> v_f;
          IF v_r_val IS NOT NULL AND jsonb_typeof(v_r_val) <> 'null'
             AND NULLIF(btrim(COALESCE(v_r_val #>> '{}', '')), '') IS NOT NULL THEN
            v_report := jsonb_set(v_report, ARRAY['types', v_t, v_f], v_r_val);
          END IF;
        END IF;
      END LOOP;
    END LOOP;
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
      'report', v_report
    ),
    'latest', v_latest
  );
END;
$function$;

COMMENT ON FUNCTION public.get_my_diet_map_access(uuid, uuid) IS
  '用户端读取 v2：商户「已发布且评分已确认」的副本优先，否则平台已发布且已确认的参考版；商户版缺失的对外名称/解析/指南图按平台参考版逐字段回退合并；不下发评分权重。';