-- ============================================================================
-- 健康饮食导图：商户开放、客户访问判定、评估提交、批量重评、覆盖率统计
-- ============================================================================

-- 按企业根商户开放 / 撤销；撤销只隐藏入口，不删任何历史评估
CREATE OR REPLACE FUNCTION public.set_diet_map_grants(
  p_template_id uuid,
  p_root_manager_ids uuid[],
  p_is_enabled boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_target uuid;
  v_name text;
  v_touched int := 0;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅平台管理员可开放或撤销饮食导图' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.diet_map_templates WHERE id = p_template_id) THEN
    RAISE EXCEPTION '饮食导图模板不存在' USING ERRCODE = 'P0002';
  END IF;

  IF p_root_manager_ids IS NULL OR COALESCE(array_length(p_root_manager_ids, 1), 0) = 0 THEN
    RAISE EXCEPTION '请先选择要操作的商户' USING ERRCODE = '22023';
  END IF;

  IF COALESCE(array_length(p_root_manager_ids, 1), 0) > 200 THEN
    RAISE EXCEPTION '一次最多操作 200 个商户，请分批处理' USING ERRCODE = '22023';
  END IF;

  FOREACH v_target IN ARRAY p_root_manager_ids LOOP
    SELECT COALESCE(NULLIF(btrim(p.nickname), ''), '该账号') INTO v_name
      FROM public.profiles p
     WHERE p.id = v_target
       AND p.role = 'manager'
       AND p.parent_manager_id IS NULL;

    IF v_name IS NULL THEN
      RAISE EXCEPTION '「%」不是企业主账号，饮食导图只能开放给企业主账号，员工与其客户会自动继承',
        COALESCE((SELECT NULLIF(btrim(nickname), '') FROM public.profiles WHERE id = v_target), v_target::text)
        USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.diet_map_grants (template_id, root_manager_id, is_enabled, granted_by, granted_at)
    VALUES (p_template_id, v_target, p_is_enabled, v_uid, now())
    ON CONFLICT (template_id, root_manager_id) DO UPDATE
      SET is_enabled = EXCLUDED.is_enabled,
          granted_by = EXCLUDED.granted_by,
          granted_at = EXCLUDED.granted_at;

    v_touched := v_touched + 1;
  END LOOP;

  RETURN jsonb_build_object('touched', v_touched, 'is_enabled', p_is_enabled);
END;
$$;

-- 客户访问判定：解析企业根 + 是否开放 + 我的最新评估摘要（永不返回 scoring 权重）
CREATE OR REPLACE FUNCTION public.get_my_diet_map_access(
  p_mp_manager uuid DEFAULT NULL,
  p_record_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_manager uuid;
  v_trusted boolean := false;
  v_tpl public.diet_map_templates%ROWTYPE;
  v_record uuid;
  v_latest jsonb := NULL;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再查看健康饮食导图' USING ERRCODE = '28000';
  END IF;

  IF p_mp_manager IS NOT NULL THEN
    v_root := public.get_enterprise_root_manager_id(p_mp_manager);
  END IF;

  -- 优先取与该企业根下任一管理师的有效绑定关系，作为归属商户
  IF v_root IS NOT NULL THEN
    SELECT cr.manager_id INTO v_manager
      FROM public.client_relations cr
      JOIN public.profiles mp ON mp.id = cr.manager_id
     WHERE cr.client_id = v_uid
       AND cr.status = 'active'
       AND COALESCE(mp.parent_manager_id, mp.id) = v_root
     ORDER BY (cr.manager_id = p_mp_manager) DESC, cr.created_at DESC
     LIMIT 1;
  ELSE
    -- 普通 H5 无 mp_manager：回落到客户自己绑定的管理师所属企业根
    SELECT cr.manager_id, COALESCE(mp.parent_manager_id, mp.id)
      INTO v_manager, v_root
      FROM public.client_relations cr
      JOIN public.profiles mp ON mp.id = cr.manager_id
     WHERE cr.client_id = v_uid
       AND cr.status = 'active'
     ORDER BY cr.created_at DESC
     LIMIT 1;
  END IF;

  IF v_root IS NULL THEN
    RETURN jsonb_build_object('open', false, 'reason', 'no_merchant');
  END IF;

  -- 可信来源：已绑定该企业下的管理师，或该企业确有启用中的品牌小程序
  v_trusted := v_manager IS NOT NULL
    OR EXISTS (
      SELECT 1 FROM public.manager_miniprograms mm
       WHERE mm.manager_id = v_root AND mm.is_enabled = true
    );

  IF NOT v_trusted THEN
    RETURN jsonb_build_object('open', false, 'reason', 'no_merchant');
  END IF;

  SELECT t.* INTO v_tpl
    FROM public.diet_map_templates t
    JOIN public.diet_map_grants g ON g.template_id = t.id
   WHERE g.root_manager_id = v_root
     AND g.is_enabled = true
     AND t.status = 'published'
   ORDER BY g.granted_at DESC
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('open', false, 'reason', 'not_granted', 'root_manager_id', v_root);
  END IF;

  -- 定位档案：显式指定优先，否则用默认档案
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
       AND a.template_id = v_tpl.id
     ORDER BY a.submitted_at DESC, a.id DESC
     LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'open', true,
    'root_manager_id', v_root,
    'manager_id', v_manager,
    'record_id', v_record,
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
$$;

-- 提交评估：校验开放 / 档案归属 / 必填与选项有效性 → 服务端评分 → 落一行新历史
CREATE OR REPLACE FUNCTION public.submit_diet_map_assessment(
  p_template_id uuid,
  p_record_id uuid,
  p_answers jsonb,
  p_prefill_meta jsonb DEFAULT '{}'::jsonb,
  p_source_composition_id uuid DEFAULT NULL,
  p_mp_manager uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_access jsonb;
  v_tpl public.diet_map_templates%ROWTYPE;
  v_q jsonb;
  v_idx int := 0;
  v_qcode text;
  v_qtitle text;
  v_qtype text;
  v_required boolean;
  v_answer text;
  v_clean jsonb := '{}'::jsonb;
  v_score jsonb;
  v_status text;
  v_type text;
  v_id uuid;
  v_manager uuid;
  v_composition uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再提交评估' USING ERRCODE = '28000';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.health_records hr WHERE hr.id = p_record_id AND hr.user_id = v_uid
  ) THEN
    RAISE EXCEPTION '找不到这份健康档案，或它不属于当前账号' USING ERRCODE = '42501';
  END IF;

  v_access := public.get_my_diet_map_access(p_mp_manager, p_record_id);

  IF NOT COALESCE((v_access ->> 'open')::boolean, false) THEN
    RAISE EXCEPTION '你所在的商户尚未开放健康饮食导图' USING ERRCODE = '42501';
  END IF;

  IF (v_access -> 'template' ->> 'id')::uuid <> p_template_id THEN
    RAISE EXCEPTION '题目版本已更新，请退出重新进入后再作答' USING ERRCODE = '40001';
  END IF;

  SELECT * INTO v_tpl FROM public.diet_map_templates WHERE id = p_template_id;

  IF jsonb_typeof(COALESCE(p_answers, 'null'::jsonb)) <> 'object' THEN
    RAISE EXCEPTION '作答内容格式不正确，请退出重新作答' USING ERRCODE = '22023';
  END IF;

  FOR v_q IN SELECT value FROM jsonb_array_elements(COALESCE(v_tpl.questions, '[]'::jsonb)) LOOP
    v_idx := v_idx + 1;
    v_qcode := NULLIF(btrim(COALESCE(v_q ->> 'code', '')), '');
    CONTINUE WHEN v_qcode IS NULL;

    v_qtitle := COALESCE(NULLIF(btrim(COALESCE(v_q ->> 'title', '')), ''), v_qcode);
    v_qtype := COALESCE(NULLIF(v_q ->> 'type', ''), 'single');
    v_required := COALESCE((v_q ->> 'required')::boolean, v_qtype = 'single');
    v_answer := NULLIF(btrim(COALESCE(p_answers ->> v_qcode, '')), '');

    IF v_answer IS NULL THEN
      IF v_required THEN
        RAISE EXCEPTION '第 % 题「%」还没有作答', v_idx, v_qtitle USING ERRCODE = '22023';
      END IF;
      CONTINUE;
    END IF;

    IF length(v_answer) > 200 THEN
      RAISE EXCEPTION '第 % 题「%」填写内容过长，请精简到 200 字以内', v_idx, v_qtitle USING ERRCODE = '22023';
    END IF;

    IF v_qtype = 'single' THEN
      IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(COALESCE(v_q -> 'options', '[]'::jsonb)) o
         WHERE o.value ->> 'code' = v_answer
      ) THEN
        RAISE EXCEPTION '第 % 题「%」的选项无效，请重新选择', v_idx, v_qtitle USING ERRCODE = '22023';
      END IF;
    ELSIF v_qtype = 'number' THEN
      IF v_answer !~ '^-?[0-9]+(\.[0-9]+)?$' THEN
        RAISE EXCEPTION '第 % 题「%」需要填写数字', v_idx, v_qtitle USING ERRCODE = '22023';
      END IF;
    END IF;

    v_clean := v_clean || jsonb_build_object(v_qcode, v_answer);
  END LOOP;

  v_score := public.diet_map_compute_score(
    v_tpl.questions, v_tpl.scoring, v_clean, v_tpl.scoring_confirmed
  );
  v_status := v_score ->> 'status';
  v_type := COALESCE(v_score ->> 'type_code', '');

  v_manager := NULLIF(v_access ->> 'manager_id', '')::uuid;

  IF p_source_composition_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.body_compositions bc
     WHERE bc.id = p_source_composition_id AND bc.record_id = p_record_id
  ) THEN
    v_composition := p_source_composition_id;
  END IF;

  INSERT INTO public.diet_map_assessments (
    template_id, config_version, user_id, record_id, manager_id,
    answers, status, type_code, scores, report_snapshot, prefill_meta, source_composition_id
  ) VALUES (
    p_template_id, v_tpl.config_version, v_uid, p_record_id, v_manager,
    v_clean, v_status, v_type, v_score -> 'scores',
    jsonb_build_object('report', v_tpl.report, 'type_code', v_type, 'snapshot_at', now()),
    CASE WHEN jsonb_typeof(COALESCE(p_prefill_meta, 'null'::jsonb)) = 'object'
         THEN p_prefill_meta ELSE '{}'::jsonb END,
    v_composition
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'assessment_id', v_id,
    'status', v_status,
    'type_code', v_type,
    'scores', v_score -> 'scores',
    'tied', v_score -> 'tied'
  );
END;
$$;

-- 批量重评：默认只补评未出结论的，force 才覆盖已评定；首次评定成功时发通知
CREATE OR REPLACE FUNCTION public.admin_rescore_diet_map(
  p_template_id uuid,
  p_force boolean DEFAULT false,
  p_limit int DEFAULT 500
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tpl public.diet_map_templates%ROWTYPE;
  v_limit int;
  v_row record;
  v_score jsonb;
  v_status text;
  v_type text;
  v_scanned int := 0;
  v_scored int := 0;
  v_pending_config int := 0;
  v_pending_tie int := 0;
  v_notified int := 0;
  v_remaining int := 0;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '仅平台管理员可批量重评' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_tpl FROM public.diet_map_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '饮食导图模板不存在' USING ERRCODE = 'P0002';
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 500), 1), 2000);

  FOR v_row IN
    SELECT a.id, a.status, a.answers, a.user_id
      FROM public.diet_map_assessments a
     WHERE a.template_id = p_template_id
       AND (COALESCE(p_force, false) OR a.status <> 'scored')
     ORDER BY a.submitted_at, a.id
     LIMIT v_limit
  LOOP
    v_scanned := v_scanned + 1;

    v_score := public.diet_map_compute_score(
      v_tpl.questions, v_tpl.scoring, v_row.answers, v_tpl.scoring_confirmed
    );
    v_status := v_score ->> 'status';
    v_type := COALESCE(v_score ->> 'type_code', '');

    UPDATE public.diet_map_assessments
       SET status = v_status,
           type_code = v_type,
           scores = v_score -> 'scores',
           config_version = v_tpl.config_version,
           report_snapshot = jsonb_build_object(
             'report', v_tpl.report, 'type_code', v_type, 'snapshot_at', now()
           )
     WHERE id = v_row.id;

    IF v_status = 'scored' THEN
      v_scored := v_scored + 1;
      IF v_row.status <> 'scored' THEN
        INSERT INTO public.notifications (user_id, type, title, body, data)
        VALUES (
          v_row.user_id,
          'diet_map_ready',
          '你的健康饮食导图已出结果',
          '评估结果已完成评定，点开可以查看你的体质分型与对应的饮食策略。',
          jsonb_build_object('assessment_id', v_row.id, 'type_code', v_type)
        );
        v_notified := v_notified + 1;
      END IF;
    ELSIF v_status = 'pending_tie' THEN
      v_pending_tie := v_pending_tie + 1;
    ELSE
      v_pending_config := v_pending_config + 1;
    END IF;
  END LOOP;

  SELECT count(*) INTO v_remaining
    FROM public.diet_map_assessments a
   WHERE a.template_id = p_template_id
     AND a.status <> 'scored';

  RETURN jsonb_build_object(
    'scanned', v_scanned,
    'scored', v_scored,
    'pending_config', v_pending_config,
    'pending_tie', v_pending_tie,
    'notified', v_notified,
    'remaining_pending', v_remaining
  );
END;
$$;

-- 覆盖率：平台端全站概览 / 商户端本企业覆盖名单（游标分页每页 50）
CREATE OR REPLACE FUNCTION public.get_diet_map_coverage(
  p_template_id uuid DEFAULT NULL,
  p_root_manager_id uuid DEFAULT NULL,
  p_cursor uuid DEFAULT NULL,
  p_limit int DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_is_admin boolean;
  v_root uuid;
  v_scope uuid[];
  v_limit int;
  v_merchant_open int := NULL;
  v_client_total int := NULL;
  v_assessed_clients int := 0;
  v_assessed_records int := 0;
  v_scored int := 0;
  v_pending int := 0;
  v_dist jsonb := '{"S":0,"D":0,"G":0,"N":0,"C":0,"A":0}'::jsonb;
  v_clients jsonb := '[]'::jsonb;
  v_next uuid := NULL;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;

  v_is_admin := public.is_admin(v_uid);
  v_limit := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 50);

  IF v_is_admin THEN
    v_root := p_root_manager_id;
  ELSE
    v_root := public.get_enterprise_root_manager_id(v_uid);
    IF v_root IS NULL THEN
      RAISE EXCEPTION '仅平台管理员或健康管理师可查看覆盖情况' USING ERRCODE = '42501';
    END IF;
    IF p_root_manager_id IS NOT NULL AND p_root_manager_id <> v_root THEN
      RAISE EXCEPTION '只能查看本企业的覆盖情况' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF v_root IS NOT NULL THEN
    SELECT array_agg(mid) INTO v_scope FROM (
      SELECT v_root AS mid
      UNION
      SELECT p.id FROM public.profiles p
       WHERE p.parent_manager_id = v_root AND p.role = 'manager'
    ) t;

    SELECT count(DISTINCT cr.client_id) INTO v_client_total
      FROM public.client_relations cr
     WHERE cr.manager_id = ANY(v_scope) AND cr.status = 'active';
  ELSE
    SELECT count(DISTINCT g.root_manager_id) INTO v_merchant_open
      FROM public.diet_map_grants g
     WHERE g.is_enabled = true
       AND (p_template_id IS NULL OR g.template_id = p_template_id);
  END IF;

  WITH latest AS (
    SELECT DISTINCT ON (a.record_id)
           a.record_id, a.user_id, a.status, a.type_code
      FROM public.diet_map_assessments a
     WHERE (p_template_id IS NULL OR a.template_id = p_template_id)
       AND (v_scope IS NULL OR a.manager_id = ANY(v_scope))
     ORDER BY a.record_id, a.submitted_at DESC, a.id DESC
  )
  SELECT
    count(DISTINCT user_id),
    count(*),
    count(*) FILTER (WHERE status = 'scored'),
    count(*) FILTER (WHERE status <> 'scored'),
    COALESCE(jsonb_object_agg(type_code, c) FILTER (WHERE type_code <> ''), '{}'::jsonb)
  INTO v_assessed_clients, v_assessed_records, v_scored, v_pending, v_dist
  FROM (
    SELECT l.user_id, l.status, l.type_code, count(*) OVER (PARTITION BY l.type_code) AS c
      FROM latest l
  ) x;

  v_dist := '{"S":0,"D":0,"G":0,"N":0,"C":0,"A":0}'::jsonb || COALESCE(v_dist, '{}'::jsonb);

  IF v_scope IS NOT NULL THEN
    WITH latest_user AS (
      SELECT DISTINCT ON (a.user_id)
             a.user_id, a.id, a.status, a.type_code, a.submitted_at
        FROM public.diet_map_assessments a
       WHERE (p_template_id IS NULL OR a.template_id = p_template_id)
         AND a.manager_id = ANY(v_scope)
       ORDER BY a.user_id, a.submitted_at DESC, a.id DESC
    ), page AS (
      SELECT cr.id AS relation_id,
             cr.client_id,
             cr.manager_id,
             COALESCE(NULLIF(btrim(cp.nickname), ''), '未命名客户') AS nickname,
             COALESCE(cp.phone, '') AS phone,
             COALESCE(cp.avatar_url, '') AS avatar_url,
             lu.id AS latest_assessment_id,
             COALESCE(lu.status, '') AS latest_status,
             COALESCE(lu.type_code, '') AS latest_type_code,
             lu.submitted_at AS latest_submitted_at
        FROM public.client_relations cr
        LEFT JOIN public.profiles cp ON cp.id = cr.client_id
        LEFT JOIN latest_user lu ON lu.user_id = cr.client_id
       WHERE cr.manager_id = ANY(v_scope)
         AND cr.status = 'active'
         AND (p_cursor IS NULL OR cr.id > p_cursor)
       ORDER BY cr.id
       LIMIT v_limit
    )
    SELECT COALESCE(jsonb_agg(to_jsonb(page) ORDER BY page.relation_id), '[]'::jsonb),
           (SELECT max(relation_id) FROM page)
      INTO v_clients, v_next
      FROM page;

    IF jsonb_array_length(v_clients) < v_limit THEN
      v_next := NULL;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'scope', CASE WHEN v_root IS NULL THEN 'global' ELSE 'merchant' END,
    'root_manager_id', v_root,
    'summary', jsonb_build_object(
      'merchant_open_count', v_merchant_open,
      'client_total', v_client_total,
      'assessed_client_count', COALESCE(v_assessed_clients, 0),
      'assessed_record_count', COALESCE(v_assessed_records, 0),
      'scored_count', COALESCE(v_scored, 0),
      'pending_count', COALESCE(v_pending, 0),
      'type_distribution', v_dist
    ),
    'clients', v_clients,
    'next_cursor', v_next
  );
END;
$$;

REVOKE ALL ON FUNCTION public.set_diet_map_grants(uuid, uuid[], boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_diet_map_access(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_diet_map_assessment(uuid, uuid, jsonb, jsonb, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_rescore_diet_map(uuid, boolean, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_diet_map_coverage(uuid, uuid, uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_diet_map_grants(uuid, uuid[], boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_diet_map_access(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_diet_map_assessment(uuid, uuid, jsonb, jsonb, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_rescore_diet_map(uuid, boolean, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_diet_map_coverage(uuid, uuid, uuid, int) TO authenticated;