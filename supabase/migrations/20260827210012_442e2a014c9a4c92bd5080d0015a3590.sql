-- 户主档案原子保存：创建/更新「本人」档案，合并占位默认档案，默认档案升降级
-- 单事务 + 按用户 advisory lock，避免并发产生多个默认档案或零默认窗口
CREATE OR REPLACE FUNCTION public.save_my_health_record(
  p_name text,
  p_relationship text,
  p_gender text,
  p_birth_date date,
  p_height numeric,
  p_weight numeric,
  p_blood_type text,
  p_record_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_name text;
  v_gender text;
  v_rel text;
  v_def record;
  v_target_id uuid;
  v_rec jsonb;
  v_action text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '登录状态已过期，请重新登录后再操作';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_uid::text));

  v_name := btrim(COALESCE(p_name, ''));
  IF v_name = '' THEN
    RAISE EXCEPTION '请填写姓名';
  END IF;
  v_rel := btrim(COALESCE(p_relationship, ''));
  IF v_rel = '' THEN
    v_rel := '本人';
  END IF;
  v_gender := btrim(COALESCE(p_gender, ''));
  IF v_gender IN ('male', 'M') THEN v_gender := '男';
  ELSIF v_gender IN ('female', 'F') THEN v_gender := '女';
  ELSIF v_gender NOT IN ('男', '女') THEN v_gender := NULL;
  END IF;

  SELECT * INTO v_def
  FROM health_records
  WHERE user_id = v_uid AND is_default = true
  ORDER BY created_at ASC, id ASC
  LIMIT 1;

  IF v_def.id IS NULL THEN
    SELECT * INTO v_def
    FROM health_records
    WHERE user_id = v_uid
    ORDER BY created_at ASC, id ASC
    LIMIT 1;
  END IF;

  IF p_record_id IS NOT NULL THEN
    SELECT id INTO v_target_id
    FROM health_records
    WHERE id = p_record_id AND user_id = v_uid;
    IF v_target_id IS NULL THEN
      RAISE EXCEPTION '档案不存在或不属于当前账号';
    END IF;
  END IF;

  IF p_record_id IS NULL THEN
    -- 新建：默认档案是占位档案（姓名空/占位 且 性别生日都空）则直接合并到它上面，保住测量与授权
    IF v_def.id IS NOT NULL
       AND (v_def.name IS NULL
            OR v_def.name = '未命名客户'
            OR v_def.name = '微信用户'
            OR v_def.name ~ '^用户\d{4}$'
            OR v_def.name ~ '^用户86\d{11}$')
       AND (v_def.gender IS NULL OR v_def.gender = '')
       AND v_def.birth_date IS NULL THEN
      UPDATE health_records
      SET name = v_name,
          relationship = v_rel,
          gender = COALESCE(v_gender, gender),
          height = COALESCE(p_height, height),
          weight = COALESCE(p_weight, weight),
          blood_type = COALESCE(NULLIF(p_blood_type, ''), blood_type),
          updated_at = now()
      WHERE id = v_def.id
      RETURNING id INTO v_target_id;
      v_action := 'merged_placeholder';
    ELSE
      INSERT INTO health_records (user_id, name, relationship, gender, birth_date, height, weight, blood_type, is_default)
      VALUES (v_uid, v_name, v_rel, v_gender, p_birth_date, p_height, p_weight, NULLIF(p_blood_type, ''), (v_def.id IS NULL))
      RETURNING id INTO v_target_id;
      v_action := CASE WHEN v_def.id IS NULL THEN 'created' ELSE 'created' END;
    END IF;
  ELSE
    -- 更新：目标档案自身更新；若目标是「本人」且当前默认是占位档案，则原子替换默认
    UPDATE health_records
    SET name = v_name,
        relationship = v_rel,
        gender = v_gender,
        birth_date = p_birth_date,
        height = p_height,
        weight = p_weight,
        blood_type = NULLIF(p_blood_type, ''),
        updated_at = now()
    WHERE id = v_target_id;

    IF v_def.id IS NOT NULL
       AND v_def.id <> v_target_id
       AND v_rel = '本人'
       AND (v_def.name IS NULL
            OR v_def.name = '未命名客户'
            OR v_def.name = '微信用户'
            OR v_def.name ~ '^用户\d{4}$'
            OR v_def.name ~ '^用户86\d{11}$')
       AND (v_def.gender IS NULL OR v_def.gender = '')
       AND v_def.birth_date IS NULL THEN
      UPDATE health_records SET is_default = false, updated_at = now() WHERE id = v_def.id;
      UPDATE health_records SET is_default = true, updated_at = now() WHERE id = v_target_id;
      v_action := 'updated_promoted';
    ELSE
      v_action := 'updated';
    END IF;
  END IF;

  SELECT jsonb_build_object('record_id', id, 'name', name, 'gender', gender, 'birth_date', birth_date, 'is_default', is_default)
  INTO v_rec
  FROM health_records
  WHERE id = v_target_id;

  RETURN jsonb_set(v_rec, '{action}', to_jsonb(v_action));
END;
$function$;

REVOKE ALL ON FUNCTION public.save_my_health_record(text, text, text, date, numeric, numeric, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_my_health_record(text, text, text, date, numeric, numeric, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.save_my_health_record(text, text, text, date, numeric, numeric, text, uuid) TO authenticated;

-- 设为默认档案：同一把用户级锁 + 单事务升降级
CREATE OR REPLACE FUNCTION public.set_my_default_record(p_record_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_target_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '登录状态已过期，请重新登录后再操作';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_uid::text));

  SELECT id INTO v_target_id
  FROM health_records
  WHERE id = p_record_id AND user_id = v_uid;
  IF v_target_id IS NULL THEN
    RAISE EXCEPTION '档案不存在或不属于当前账号';
  END IF;

  UPDATE health_records SET is_default = false, updated_at = now()
  WHERE user_id = v_uid AND is_default = true AND id <> v_target_id;
  UPDATE health_records SET is_default = true, updated_at = now()
  WHERE id = v_target_id;

  RETURN 'ok';
END;
$function$;

REVOKE ALL ON FUNCTION public.set_my_default_record(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_my_default_record(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_my_default_record(uuid) TO authenticated;