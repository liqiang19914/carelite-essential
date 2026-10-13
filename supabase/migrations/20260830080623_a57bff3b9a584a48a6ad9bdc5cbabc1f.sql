-- feature 398: 免登录分享公开页数据层。
-- share_links：分享票据表。token 22 位 base64url（128bit 随机熵）；kind 互斥；
-- 源记录删除即 CASCADE 失效；anon/authenticated 无任何直表权限，只能经公开 RPC 读白名单数据包。

CREATE TABLE IF NOT EXISTS public.share_links (
  token varchar(22) PRIMARY KEY CHECK (token ~ '^[A-Za-z0-9_-]{22}$'),
  kind text NOT NULL CHECK (kind IN ('weighing', 'compare', 'dietmap')),
  creator_user_id uuid NOT NULL,
  root_manager_id uuid,
  weighing_id uuid REFERENCES public.body_compositions(id) ON DELETE CASCADE,
  compare_left_id uuid REFERENCES public.body_compositions(id) ON DELETE CASCADE,
  compare_right_id uuid REFERENCES public.body_compositions(id) ON DELETE CASCADE,
  diet_map_assessment_id uuid REFERENCES public.diet_map_assessments(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT share_links_kind_exclusive CHECK (
    (
      kind = 'weighing'
      AND weighing_id IS NOT NULL
      AND compare_left_id IS NULL
      AND compare_right_id IS NULL
      AND diet_map_assessment_id IS NULL
    )
    OR (
      kind = 'compare'
      AND compare_left_id IS NOT NULL
      AND compare_right_id IS NOT NULL
      AND compare_left_id::text < compare_right_id::text
      AND weighing_id IS NULL
      AND diet_map_assessment_id IS NULL
    )
    OR (
      kind = 'dietmap'
      AND diet_map_assessment_id IS NOT NULL
      AND weighing_id IS NULL
      AND compare_left_id IS NULL
      AND compare_right_id IS NULL
    )
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_share_links_weighing_idem
  ON public.share_links
  (creator_user_id, COALESCE(root_manager_id, '00000000-0000-0000-0000-000000000000'::uuid), weighing_id)
  WHERE kind = 'weighing';

CREATE UNIQUE INDEX IF NOT EXISTS uq_share_links_compare_idem
  ON public.share_links
  (creator_user_id, COALESCE(root_manager_id, '00000000-0000-0000-0000-000000000000'::uuid), compare_left_id, compare_right_id)
  WHERE kind = 'compare';

CREATE UNIQUE INDEX IF NOT EXISTS uq_share_links_dietmap_idem
  ON public.share_links
  (creator_user_id, COALESCE(root_manager_id, '00000000-0000-0000-0000-000000000000'::uuid), diet_map_assessment_id)
  WHERE kind = 'dietmap';

ALTER TABLE public.share_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.share_links FROM anon, authenticated;

-- 单条测量的展示数据包：只吃传入值，不访问任何表；字段白名单在此收口，
-- 绝不外送 id / record_id / provider_key / device_ref / notes / oem_manager_id。
CREATE OR REPLACE FUNCTION public.share_measure_package(
  p_row public.body_compositions,
  p_member_name text,
  p_gender text,
  p_height_cm numeric,
  p_age_at_measure integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $function$
BEGIN
  RETURN jsonb_build_object(
    'memberName', p_member_name,
    'gender', CASE WHEN p_gender IN ('male', '男') THEN 'male'
                   WHEN p_gender IN ('female', '女') THEN 'female'
                   ELSE NULL END,
    'heightCm', p_height_cm,
    'ageAtMeasure', p_age_at_measure,
    'measuredAt', p_row.measured_at,
    'origin', p_row.origin,
    'weight', p_row.weight,
    'heartRate', p_row.heart_rate,
    'heartIndex', p_row.heart_index,
    'bmi', p_row.bmi,
    'bodyFatPercent', p_row.body_fat_percent,
    'waterPercent', p_row.water_percent,
    'skeletalMusclePercent', p_row.skeletal_muscle_percent,
    'musclePercent', p_row.muscle_percent,
    'muscleMass', p_row.muscle_mass,
    'boneMass', p_row.bone_mass,
    'lbm', p_row.lbm,
    'proteinPercent', p_row.protein_percent,
    'subcutaneousFatPercent', p_row.subcutaneous_fat_percent,
    'visceralFatLevel', p_row.visceral_fat_level,
    'bodyAge', p_row.body_age,
    'bodyShape', p_row.body_shape,
    'bmr', p_row.bmr,
    'muscleStorageScore', p_row.muscle_storage_score,
    'healthScore', p_row.health_score,
    'metricsMeta', p_row.metrics_meta,
    'missingMetrics', p_row.missing_metrics
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.share_measure_package(public.body_compositions, text, text, numeric, integer) FROM PUBLIC;

COMMENT ON FUNCTION public.share_measure_package(public.body_compositions, text, text, numeric, integer) IS
  '把一条体成分测量组装成分享公开页的展示数据包。纯转换函数：只吃传入值，白名单收口展示字段，绝不返回内部 id / 设备引用 / 备注。';

-- 创建分享链接（登录者本人，来源必须在自己名下）。幂等：同一人 + 同一来源 + 同一品牌根重复创建返回原 token。
CREATE OR REPLACE FUNCTION public.create_health_share_link(
  p_kind text,
  p_primary_id uuid,
  p_secondary_id uuid DEFAULT NULL,
  p_root_manager_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_weighing_id uuid;
  v_compare_left uuid;
  v_compare_right uuid;
  v_dietmap_id uuid;
  v_record_id uuid;
  v_other_record uuid;
  v_oem uuid;
  v_root uuid;
  v_token text;
  v_attempt integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再分享' USING ERRCODE = '28000';
  END IF;

  IF p_kind = 'weighing' THEN
    SELECT b.id, b.oem_manager_id
      INTO v_weighing_id, v_oem
      FROM public.body_compositions b
      JOIN public.health_records h ON h.id = b.record_id
     WHERE b.id = p_primary_id AND h.user_id = v_uid;
    IF v_weighing_id IS NULL THEN
      RAISE EXCEPTION '记录不存在或不在你名下' USING ERRCODE = '42501';
    END IF;
  ELSIF p_kind = 'compare' THEN
    IF p_secondary_id IS NULL THEN
      RAISE EXCEPTION '对比分享需要两条测量记录' USING ERRCODE = '22023';
    END IF;
    SELECT b.id, b.record_id, b.oem_manager_id
      INTO v_weighing_id, v_record_id, v_oem
      FROM public.body_compositions b
      JOIN public.health_records h ON h.id = b.record_id
     WHERE b.id = p_primary_id AND h.user_id = v_uid;
    IF v_weighing_id IS NULL THEN
      RAISE EXCEPTION '记录不存在或不在你名下' USING ERRCODE = '42501';
    END IF;
    SELECT b.record_id
      INTO v_other_record
      FROM public.body_compositions b
      JOIN public.health_records h ON h.id = b.record_id
     WHERE b.id = p_secondary_id AND h.user_id = v_uid;
    IF v_other_record IS NULL THEN
      RAISE EXCEPTION '记录不存在或不在你名下' USING ERRCODE = '42501';
    END IF;
    IF v_other_record <> v_record_id THEN
      RAISE EXCEPTION '两次测量不属于同一份档案' USING ERRCODE = '22023';
    END IF;
    v_compare_left := LEAST(p_primary_id::text, p_secondary_id::text)::uuid;
    v_compare_right := GREATEST(p_primary_id::text, p_secondary_id::text)::uuid;
  ELSIF p_kind = 'dietmap' THEN
    SELECT a.id,
           COALESCE(
             NULLIF(btrim(COALESCE(a.report_snapshot ->> 'root_manager_id', '')), '')::uuid,
             a.root_manager_id
           )
      INTO v_dietmap_id, v_root
      FROM public.diet_map_assessments a
     WHERE a.id = p_primary_id AND a.user_id = v_uid;
    IF v_dietmap_id IS NULL THEN
      RAISE EXCEPTION '导图不存在或不在你名下' USING ERRCODE = '42501';
    END IF;
  ELSE
    RAISE EXCEPTION '分享类型无效' USING ERRCODE = '22023';
  END IF;

  -- 称重 / 对比的品牌根从测量记录的商户盖章解析，绝不信任调用方传入的商户参数
  IF p_kind <> 'dietmap' THEN
    v_root := public.get_enterprise_root_manager_id(v_oem);
  END IF;

  IF p_kind = 'weighing' THEN
    SELECT s.token INTO v_token
      FROM public.share_links s
     WHERE s.kind = 'weighing'
       AND s.creator_user_id = v_uid
       AND s.weighing_id = v_weighing_id
       AND COALESCE(s.root_manager_id, '00000000-0000-0000-0000-000000000000'::uuid)
         = COALESCE(v_root, '00000000-0000-0000-0000-000000000000'::uuid)
     LIMIT 1;
  ELSIF p_kind = 'compare' THEN
    SELECT s.token INTO v_token
      FROM public.share_links s
     WHERE s.kind = 'compare'
       AND s.creator_user_id = v_uid
       AND s.compare_left_id = v_compare_left
       AND s.compare_right_id = v_compare_right
       AND COALESCE(s.root_manager_id, '00000000-0000-0000-0000-000000000000'::uuid)
         = COALESCE(v_root, '00000000-0000-0000-0000-000000000000'::uuid)
     LIMIT 1;
  ELSE
    SELECT s.token INTO v_token
      FROM public.share_links s
     WHERE s.kind = 'dietmap'
       AND s.creator_user_id = v_uid
       AND s.diet_map_assessment_id = v_dietmap_id
       AND COALESCE(s.root_manager_id, '00000000-0000-0000-0000-000000000000'::uuid)
         = COALESCE(v_root, '00000000-0000-0000-0000-000000000000'::uuid)
     LIMIT 1;
  END IF;

  IF v_token IS NOT NULL THEN
    RETURN jsonb_build_object('token', v_token);
  END IF;

  WHILE v_attempt < 3 LOOP
    v_attempt := v_attempt + 1;
    v_token := replace(translate(encode(extensions.gen_random_bytes(16), 'base64'), '+/', '-_'), '=', '');
    BEGIN
      INSERT INTO public.share_links
        (token, kind, creator_user_id, root_manager_id, weighing_id, compare_left_id, compare_right_id, diet_map_assessment_id)
      VALUES
        (v_token, p_kind, v_uid, v_root, v_weighing_id, v_compare_left, v_compare_right, v_dietmap_id);
      RETURN jsonb_build_object('token', v_token);
    EXCEPTION WHEN unique_violation THEN
      -- 撞 token 主键（别人抽到同值）或并发幂等重：按幂等键回查，查到即复用
      SELECT s.token INTO v_token
        FROM public.share_links s
       WHERE s.creator_user_id = v_uid
         AND s.kind = p_kind
         AND COALESCE(s.root_manager_id, '00000000-0000-0000-0000-000000000000'::uuid)
           = COALESCE(v_root, '00000000-0000-0000-0000-000000000000'::uuid)
         AND (
           (p_kind = 'weighing' AND s.weighing_id = v_weighing_id)
           OR (p_kind = 'compare' AND s.compare_left_id = v_compare_left AND s.compare_right_id = v_compare_right)
           OR (p_kind = 'dietmap' AND s.diet_map_assessment_id = v_dietmap_id)
         )
       LIMIT 1;
      IF v_token IS NOT NULL THEN
        RETURN jsonb_build_object('token', v_token);
      END IF;
    END;
  END LOOP;

  RAISE EXCEPTION '分享创建失败，请稍后再试';
END;
$function$;

REVOKE ALL ON FUNCTION public.create_health_share_link(text, uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_health_share_link(text, uuid, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.create_health_share_link(text, uuid, uuid, uuid) IS
  '为本人名下的单次称重 / 同档案两条测量对比 / 饮食导图创建免登录分享 token。22 位 base64url；按创建者+来源+品牌根幂等（重复创建返回原 token）。品牌根服务端解析：称重与对比取测量的商户盖章所属企业根，导图取评估快照里的归属；调用方传入的商户参数一律不信任。';

-- 公开读取分享数据包（anon 可用）。不存在 / 来源已删 / 对比缺一条统一返回 invalid，不泄露存在性。
CREATE OR REPLACE FUNCTION public.get_public_health_share(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_invalid jsonb := jsonb_build_object('status', 'invalid');
  v_share public.share_links%ROWTYPE;
  v_row public.body_compositions%ROWTYPE;
  v_earlier public.body_compositions%ROWTYPE;
  v_later public.body_compositions%ROWTYPE;
  v_tmp public.body_compositions%ROWTYPE;
  v_assessment public.diet_map_assessments%ROWTYPE;
  v_snapshot jsonb;
  v_member_name text;
  v_gender_raw text;
  v_height numeric;
  v_birth date;
  v_age integer;
  v_bmr numeric;
  v_brand_name text;
  v_brand_logo text;
  v_brand_color text;
  v_enterprise_name text;
  v_brand jsonb;
BEGIN
  IF p_token IS NULL OR p_token !~ '^[A-Za-z0-9_-]{22}$' THEN
    RETURN v_invalid;
  END IF;

  SELECT * INTO v_share FROM public.share_links WHERE token = p_token;
  IF v_share.token IS NULL THEN
    RETURN v_invalid;
  END IF;

  -- 品牌解析：商户名 → 企业名兜底；查不到任何素材时置空，前端降级平台品牌
  IF v_share.root_manager_id IS NOT NULL THEN
    SELECT NULLIF(btrim(COALESCE(mm.brand_name, '')), ''),
           NULLIF(btrim(COALESCE(mm.brand_logo_url, '')), ''),
           NULLIF(btrim(COALESCE(mm.brand_primary_color, '')), '')
      INTO v_brand_name, v_brand_logo, v_brand_color
      FROM public.manager_miniprograms mm
     WHERE mm.manager_id = v_share.root_manager_id;
    IF v_brand_name IS NULL THEN
      SELECT e.name INTO v_enterprise_name
        FROM public.profiles p
        JOIN public.enterprises e ON e.id = p.enterprise_id
       WHERE p.id = v_share.root_manager_id;
      v_brand_name := v_enterprise_name;
    END IF;
    IF COALESCE(v_brand_name, v_brand_logo, v_brand_color) IS NOT NULL THEN
      v_brand := jsonb_build_object('name', v_brand_name, 'logoUrl', v_brand_logo, 'primaryColor', v_brand_color);
    END IF;
  END IF;

  IF v_share.kind = 'weighing' THEN
    SELECT b.* INTO v_row FROM public.body_compositions b WHERE b.id = v_share.weighing_id;
    IF v_row.id IS NULL THEN
      RETURN v_invalid;
    END IF;
    SELECT h.name, h.gender, h.height, h.birth_date
      INTO v_member_name, v_gender_raw, v_height, v_birth
      FROM public.health_records h
     WHERE h.id = v_row.record_id;
    v_age := CASE WHEN v_birth IS NULL THEN NULL
                  ELSE EXTRACT(YEAR FROM AGE(v_row.measured_at::date, v_birth))::integer END;
    RETURN jsonb_build_object(
      'status', 'ok',
      'kind', 'weighing',
      'data', public.share_measure_package(v_row, v_member_name, v_gender_raw, v_height, v_age),
      'brand', v_brand,
      'sharedAt', v_share.created_at
    );
  ELSIF v_share.kind = 'compare' THEN
    SELECT b.* INTO v_earlier FROM public.body_compositions b WHERE b.id = v_share.compare_left_id;
    SELECT b.* INTO v_later FROM public.body_compositions b WHERE b.id = v_share.compare_right_id;
    IF v_earlier.id IS NULL OR v_later.id IS NULL THEN
      RETURN v_invalid;
    END IF;
    IF v_earlier.measured_at > v_later.measured_at THEN
      v_tmp := v_earlier;
      v_earlier := v_later;
      v_later := v_tmp;
    END IF;
    SELECT h.name, h.gender, h.height, h.birth_date
      INTO v_member_name, v_gender_raw, v_height, v_birth
      FROM public.health_records h
     WHERE h.id = v_earlier.record_id;
    v_age := CASE WHEN v_birth IS NULL THEN NULL
                  ELSE EXTRACT(YEAR FROM AGE(v_earlier.measured_at::date, v_birth))::integer END;
    RETURN jsonb_build_object(
      'status', 'ok',
      'kind', 'compare',
      'data', jsonb_build_object(
        'earlier', public.share_measure_package(v_earlier, v_member_name, v_gender_raw, v_height, v_age),
        'later', public.share_measure_package(
          v_later, v_member_name, v_gender_raw, v_height,
          CASE WHEN v_birth IS NULL THEN NULL
               ELSE EXTRACT(YEAR FROM AGE(v_later.measured_at::date, v_birth))::integer END
        )
      ),
      'brand', v_brand,
      'sharedAt', v_share.created_at
    );
  ELSIF v_share.kind = 'dietmap' THEN
    SELECT a.* INTO v_assessment FROM public.diet_map_assessments a WHERE a.id = v_share.diet_map_assessment_id;
    IF v_assessment.id IS NULL THEN
      RETURN v_invalid;
    END IF;
    v_snapshot := v_assessment.report_snapshot;
    IF v_assessment.source_composition_id IS NOT NULL THEN
      SELECT b.bmr INTO v_bmr FROM public.body_compositions b WHERE b.id = v_assessment.source_composition_id;
    END IF;
    IF v_bmr IS NULL THEN
      SELECT b.bmr INTO v_bmr
        FROM public.body_compositions b
       WHERE b.record_id = v_assessment.record_id
       ORDER BY b.measured_at DESC
       LIMIT 1;
    END IF;
    SELECT h.name, h.gender INTO v_member_name, v_gender_raw
      FROM public.health_records h
     WHERE h.id = v_assessment.record_id;
    RETURN jsonb_build_object(
      'status', 'ok',
      'kind', 'dietmap',
      'data', jsonb_build_object(
        'status', v_assessment.status,
        'typeCode', v_assessment.type_code,
        'verdict', v_assessment.verdict,
        'scores', v_assessment.scores,
        'report', v_snapshot -> 'report',
        'questions', v_snapshot -> 'questions',
        'answers', v_assessment.answers,
        'prefillMeta', v_assessment.prefill_meta,
        'submittedAt', v_assessment.submitted_at,
        'memberName', v_member_name,
        'gender', CASE WHEN v_gender_raw IN ('male', '男') THEN 'male'
                       WHEN v_gender_raw IN ('female', '女') THEN 'female'
                       ELSE NULL END,
        'bmr', v_bmr
      ),
      'brand', v_brand,
      'sharedAt', v_share.created_at
    );
  END IF;

  RETURN v_invalid;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_health_share(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_health_share(text) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.get_public_health_share(text) IS
  '免登录读取分享数据包。token 不存在、来源已删除（外键 CASCADE 带走分享行）或对比缺一条时统一返回 status=invalid，不泄露存在性。只返回展示白名单字段：无 user_id / record_id / 内部 UUID / 设备引用 / 备注；档案参数只给性别、身高与测量当天年龄，不给出生日期。品牌按 root_manager_id 解析，查不到一律降级平台品牌而不报错。';