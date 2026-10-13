-- 在公开分享页 brand 里补上商户的体重单位设置，让分享出去的页面和 App 内显示一致（斤/公斤）。
-- weightUnit 取值：'jin' / 'kg' / null（user_choice 或未设置时返回 null，前端默认 kg）。
-- 纯幂等 CREATE OR REPLACE，可安全重放。

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
  v_weight_unit text;
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

    -- 体重单位：只读 jin/kg 两种固定模式；user_choice 或未设置 → 返回 null，前端默认 kg
    SELECT CASE WHEN wus.weight_unit_mode IN ('jin', 'kg') THEN wus.weight_unit_mode ELSE NULL END
      INTO v_weight_unit
      FROM public.merchant_weight_unit_settings wus
     WHERE wus.root_manager_id = v_share.root_manager_id;

    IF COALESCE(v_brand_name, v_brand_logo, v_brand_color, v_weight_unit) IS NOT NULL THEN
      v_brand := jsonb_build_object(
        'name', v_brand_name,
        'logoUrl', v_brand_logo,
        'primaryColor', v_brand_color,
        'weightUnit', v_weight_unit
      );
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
        'later', public.share_measure_package(v_later, v_member_name, v_gender_raw, v_height, v_age)
      ),
      'brand', v_brand,
      'sharedAt', v_share.created_at
    );
  ELSIF v_share.kind = 'dietmap' THEN
    SELECT a.* INTO v_assessment
      FROM public.diet_map_assessments a
     WHERE a.id = v_share.dietmap_id;
    IF v_assessment.id IS NULL THEN
      RETURN v_invalid;
    END IF;
    SELECT h.name, h.gender, h.height, h.birth_date
      INTO v_member_name, v_gender_raw, v_height, v_birth
      FROM public.health_records h
     WHERE h.id = v_assessment.record_id;
    v_age := CASE WHEN v_birth IS NULL THEN NULL
                  ELSE EXTRACT(YEAR FROM AGE(v_assessment.submitted_at::date, v_birth))::integer END;
    v_bmr := CASE WHEN v_height IS NOT NULL AND v_assessment.gender IS NOT NULL AND v_age IS NOT NULL
                  THEN public.estimate_bmr(v_assessment.gender, v_height, v_age)
                  ELSE NULL END;
    RETURN jsonb_build_object(
      'status', 'ok',
      'kind', 'dietmap',
      'data', jsonb_build_object(
        'assessment', public.diet_map_assessment_package(v_assessment),
        'memberName', v_member_name,
        'gender', CASE WHEN v_assessment.gender IN ('male', '男') THEN 'male'
                       WHEN v_assessment.gender IN ('female', '女') THEN 'female'
                       ELSE NULL END,
        'bmr', v_bmr
      ),
      'brand', v_brand,
      'sharedAt', v_share.created_at
    );
  ELSE
    RETURN v_invalid;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_health_share(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_health_share(text) TO anon, authenticated;

COMMENT ON FUNCTION public.get_public_health_share(text) IS
  '免登录读取分享数据包。token 不存在、来源已删除（外键 CASCADE 带走分享行）或对比缺一条时统一返回 status=invalid，不泄露存在性。只返回展示白名单字段：无 user_id / record_id / 内部 UUID / 设备引用 / 备注；档案参数只给性别、身高与测量当天年龄，不给出生日期。品牌按 root_manager_id 解析，查不到一律降级平台品牌而不报错。自本迁移起 brand.weightUnit 从 merchant_weight_unit_settings 读取（jin/kg 两种固定模式，user_choice 或未设置返回 null 前端默认 kg）。';
