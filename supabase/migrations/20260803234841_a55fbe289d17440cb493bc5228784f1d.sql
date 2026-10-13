-- ============================================================================
-- 健康饮食导图 V1：商户圆心品牌解析 + 表头/正式题分离 + 结构校验加严
-- ============================================================================

-- 客户按 client_id 反查自己绑定的管理师：既有索引以 manager_id 打头，用不上
CREATE INDEX IF NOT EXISTS idx_client_relations_client_status_created
  ON public.client_relations (client_id, status, created_at DESC);

-- ----------------------------------------------------------------------------
-- 1) 圆心 Logo 归属解析
--    绝不接受调用方传进来的 manager_id：只按「登录身份」或「这份评估自己记着的归属」
--    反查，避免任何人拿别家商户的 ID 换出别家的品牌资料。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_diet_map_brand(
  p_assessment_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_owner uuid;
  v_name text;
  v_full text;
  v_logo text;
  v_enabled boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再查看所属机构信息' USING ERRCODE = '28000';
  END IF;

  IF p_assessment_id IS NOT NULL THEN
    SELECT a.user_id,
           COALESCE(
             NULLIF(btrim(COALESCE(a.report_snapshot ->> 'root_manager_id', '')), '')::uuid,
             public.get_enterprise_root_manager_id(a.manager_id)
           )
      INTO v_owner, v_root
      FROM public.diet_map_assessments a
     WHERE a.id = p_assessment_id;

    IF v_owner IS NULL THEN
      RETURN jsonb_build_object('found', false, 'reason', 'not_found');
    END IF;

    IF v_owner <> v_uid
       AND NOT public.diet_map_is_my_client(v_owner, v_uid)
       AND NOT public.is_admin(v_uid) THEN
      RAISE EXCEPTION '你没有查看这份导图的权限' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- 管理师本人或子账号：直接用自己的企业根
  IF v_root IS NULL THEN
    v_root := public.get_enterprise_root_manager_id(v_uid);
  END IF;

  -- 客户：用自己有效绑定的管理师所属企业根（与入口路径无关，普通 H5 登录同样成立）
  IF v_root IS NULL THEN
    SELECT COALESCE(mp.parent_manager_id, mp.id)
      INTO v_root
      FROM public.client_relations cr
      JOIN public.profiles mp ON mp.id = cr.manager_id
     WHERE cr.client_id = v_uid
       AND cr.status = 'active'
     ORDER BY cr.created_at DESC
     LIMIT 1;
  END IF;

  -- 没有归属不是错误：客户端据此回退成机构名文字，绝不显示平台助手头像
  IF v_root IS NULL THEN
    RETURN jsonb_build_object('found', false, 'reason', 'no_merchant');
  END IF;

  SELECT NULLIF(btrim(COALESCE(mm.brand_name, '')), ''),
         NULLIF(btrim(COALESCE(mm.brand_full_name, '')), ''),
         NULLIF(btrim(COALESCE(mm.brand_logo_url, '')), ''),
         COALESCE(mm.is_enabled, false)
    INTO v_name, v_full, v_logo, v_enabled
    FROM public.manager_miniprograms mm
   WHERE mm.manager_id = v_root;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'found', false,
      'reason', 'no_oem_config',
      'root_manager_id', v_root
    );
  END IF;

  RETURN jsonb_build_object(
    'found', true,
    'root_manager_id', v_root,
    'brand_name', COALESCE(v_name, ''),
    'brand_full_name', COALESCE(v_full, ''),
    'brand_logo_url', COALESCE(v_logo, ''),
    'oem_enabled', v_enabled
  );
END;
$$;

COMMENT ON FUNCTION public.get_my_diet_map_brand(uuid) IS
  '解析当前登录者所属商户（企业根）的品牌名与圆心 Logo。传评估 ID 时先校验查看权限，并按该评估记录的归属解析，保证历史报告的圆心 Logo 不随客户换绑而改变。永不接受调用方提交的 manager_id。没有归属时返回 found=false 而非报错，让客户端优雅回退成机构名文字。';

REVOKE ALL ON FUNCTION public.get_my_diet_map_brand(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_diet_map_brand(uuid) TO authenticated;

-- ----------------------------------------------------------------------------
-- 2) 评分：表头基本信息不参与计分
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.diet_map_compute_score(
  p_questions jsonb,
  p_scoring jsonb,
  p_answers jsonb,
  p_scoring_confirmed boolean
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_types text[] := ARRAY['S','D','G','N','C','A'];
  v_weights jsonb;
  v_tie jsonb;
  v_scores jsonb := '{}'::jsonb;
  v_q jsonb;
  v_qcode text;
  v_answer text;
  v_ow jsonb;
  v_t text;
  v_total numeric := 0;
  v_cur numeric;
  v_max numeric := -1;
  v_tops text[] := ARRAY[]::text[];
  v_pick text;
  v_i int;
BEGIN
  FOREACH v_t IN ARRAY v_types LOOP
    v_scores := v_scores || jsonb_build_object(v_t, 0);
  END LOOP;

  IF NOT COALESCE(p_scoring_confirmed, false) THEN
    RETURN jsonb_build_object('status', 'pending_config', 'type_code', '', 'scores', v_scores);
  END IF;

  v_weights := p_scoring -> 'weights';
  IF v_weights IS NULL OR jsonb_typeof(v_weights) <> 'object' THEN
    RETURN jsonb_build_object('status', 'pending_config', 'type_code', '', 'scores', v_scores);
  END IF;

  FOR v_q IN SELECT value FROM jsonb_array_elements(COALESCE(p_questions, '[]'::jsonb)) LOOP
    v_qcode := NULLIF(btrim(COALESCE(v_q ->> 'code', '')), '');
    CONTINUE WHEN v_qcode IS NULL;
    CONTINUE WHEN COALESCE(NULLIF(v_q ->> 'type', ''), 'single') <> 'single';
    -- 表头的「性别」等字段也是单选，但它只用于报告落款，不参与体质分型
    CONTINUE WHEN COALESCE(NULLIF(v_q ->> 'role', ''), 'assessment') = 'header';

    v_answer := NULLIF(btrim(COALESCE(p_answers ->> v_qcode, '')), '');
    CONTINUE WHEN v_answer IS NULL;

    v_ow := v_weights -> v_qcode -> v_answer;
    CONTINUE WHEN v_ow IS NULL OR jsonb_typeof(v_ow) <> 'object';

    FOREACH v_t IN ARRAY v_types LOOP
      v_scores := jsonb_set(
        v_scores,
        ARRAY[v_t],
        to_jsonb(
          COALESCE((v_scores ->> v_t)::numeric, 0)
          + COALESCE(NULLIF(v_ow ->> v_t, '')::numeric, 0)
        )
      );
    END LOOP;
  END LOOP;

  FOREACH v_t IN ARRAY v_types LOOP
    v_total := v_total + COALESCE((v_scores ->> v_t)::numeric, 0);
  END LOOP;

  IF v_total <= 0 THEN
    RETURN jsonb_build_object('status', 'pending_config', 'type_code', '', 'scores', v_scores);
  END IF;

  FOREACH v_t IN ARRAY v_types LOOP
    v_cur := COALESCE((v_scores ->> v_t)::numeric, 0);
    IF v_cur > v_max THEN
      v_max := v_cur;
      v_tops := ARRAY[v_t];
    ELSIF v_cur = v_max THEN
      v_tops := v_tops || v_t;
    END IF;
  END LOOP;

  IF COALESCE(array_length(v_tops, 1), 0) = 1 THEN
    RETURN jsonb_build_object('status', 'scored', 'type_code', v_tops[1], 'scores', v_scores);
  END IF;

  -- 平局：只认显式平局序，绝不按字母序兜底
  v_tie := p_scoring -> 'tieBreak';
  IF v_tie IS NOT NULL AND jsonb_typeof(v_tie) = 'array' AND jsonb_array_length(v_tie) > 0 THEN
    FOR v_i IN 0 .. jsonb_array_length(v_tie) - 1 LOOP
      v_pick := v_tie ->> v_i;
      IF v_pick = ANY(v_tops) THEN
        RETURN jsonb_build_object('status', 'scored', 'type_code', v_pick, 'scores', v_scores);
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'status', 'pending_tie', 'type_code', '', 'scores', v_scores, 'tied', to_jsonb(v_tops)
  );
END;
$$;

COMMENT ON FUNCTION public.diet_map_compute_score(jsonb, jsonb, jsonb, boolean) IS
  '纯函数：按声明式权重表计算六型得分，只统计 role<>header 的单选题。未经客户方确认、权重缺失或总分为 0 一律返回 pending_config；多型同分且无显式平局序返回 pending_tie，绝不按字母序兜底。';
