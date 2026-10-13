-- 修复：compare 分支曾把第一条测量 id 存进 v_weighing_id，INSERT 时误填 weighing_id 列触发互斥 CHECK。
-- compare 分支改用独立变量 v_first_id，weighing_id 仅在 weighing 分支赋值。
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
  v_first_id uuid;
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
      INTO v_first_id, v_record_id, v_oem
      FROM public.body_compositions b
      JOIN public.health_records h ON h.id = b.record_id
     WHERE b.id = p_primary_id AND h.user_id = v_uid;
    IF v_first_id IS NULL THEN
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