-- 审查修复①：模板的受保护字段改为「只能走正式接口改」。
-- 原来 authenticated 持有整表 UPDATE，企业管理员直接改表就能把 status 置成
-- published、把 scoring_confirmed 置成 true，完全绕过配置校验与分值确认闸门。
-- 改成列级授权后，这几列只能由 SECURITY DEFINER 接口（发布 / 确认分值）写入。
REVOKE UPDATE ON TABLE public.diet_map_templates FROM authenticated;
REVOKE UPDATE ON TABLE public.diet_map_templates FROM anon;
GRANT UPDATE (title, description, questions, scoring, report, updated_at)
  ON TABLE public.diet_map_templates TO authenticated;

-- 审查修复②：管理师读客户评估时补上企业归属。
-- 一位客户可以同时属于多家商户，只按「是我的客户」放行会让 A 家读到这位客户
-- 在 B 家答的卷子。存量 root 为空的行按提交时的管理师换算企业根，与覆盖统计口径一致。
DROP POLICY IF EXISTS "Manager view client diet map assessments" ON public.diet_map_assessments;
CREATE POLICY "Manager view client diet map assessments"
  ON public.diet_map_assessments FOR SELECT
  USING (
    public.diet_map_is_my_client(user_id, auth.uid())
    AND (
      root_manager_id = public.get_enterprise_root_manager_id(auth.uid())
      OR (
        root_manager_id IS NULL
        AND manager_id IS NOT NULL
        AND public.get_enterprise_root_manager_id(manager_id)
            = public.get_enterprise_root_manager_id(auth.uid())
      )
    )
  );

-- 审查修复③：平台重评参考版时跳过「已经发布自有版本」的商户。
-- 那些商户切版本前的历史评估仍挂在参考版的 template_id 下，按 template_id 一网打尽
-- 会用平台配置覆盖别人店里的结论；他们的历史由商户自己在本店重评。
CREATE OR REPLACE FUNCTION public.admin_rescore_diet_map(p_template_id uuid, p_force boolean DEFAULT false, p_limit integer DEFAULT 500)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_tpl public.diet_map_templates%ROWTYPE;
  v_limit int;
  v_row record;
  v_score jsonb;
  v_status text;
  v_type text;
  v_questions jsonb;
  v_scanned int := 0;
  v_scored int := 0;
  v_pending_config int := 0;
  v_pending_tie int := 0;
  v_notified int := 0;
  v_remaining int := 0;
BEGIN
  IF NOT public.diet_map_can_manage_template(p_template_id, v_uid) THEN
    RAISE EXCEPTION '当前账号没有权限批量重评这份饮食导图' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_tpl FROM public.diet_map_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '饮食导图模板不存在' USING ERRCODE = 'P0002';
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 500), 1), 2000);

  FOR v_row IN
    SELECT a.id, a.status, a.answers, a.user_id, a.manager_id, a.root_manager_id, a.report_snapshot
      FROM public.diet_map_assessments a
     WHERE (
             CASE WHEN v_tpl.root_manager_id IS NULL
                  THEN a.template_id = p_template_id
                       AND NOT EXISTS (
                             SELECT 1
                               FROM public.diet_map_templates m
                              WHERE m.root_manager_id = a.root_manager_id
                                AND m.source_template_id = p_template_id
                                AND m.status = 'published'
                           )
                  ELSE a.root_manager_id = v_tpl.root_manager_id
             END
           )
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

    v_questions := CASE
      WHEN jsonb_typeof(v_row.report_snapshot -> 'questions') = 'array'
        THEN v_row.report_snapshot -> 'questions'
      ELSE v_tpl.questions
    END;

    UPDATE public.diet_map_assessments
       SET status = v_status,
           type_code = v_type,
           scores = v_score -> 'scores',
           config_version = v_tpl.config_version,
           report_snapshot = jsonb_build_object(
             'report', v_tpl.report,
             'questions', v_questions,
             'root_manager_id', COALESCE(
               v_row.root_manager_id,
               NULLIF(btrim(COALESCE(v_row.report_snapshot ->> 'root_manager_id', '')), '')::uuid,
               public.get_enterprise_root_manager_id(v_row.manager_id)
             ),
             'type_code', v_type,
             'snapshot_at', now()
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
   WHERE (
           CASE WHEN v_tpl.root_manager_id IS NULL
                THEN a.template_id = p_template_id
                     AND NOT EXISTS (
                           SELECT 1
                             FROM public.diet_map_templates m
                            WHERE m.root_manager_id = a.root_manager_id
                              AND m.source_template_id = p_template_id
                              AND m.status = 'published'
                         )
                ELSE a.root_manager_id = v_tpl.root_manager_id
           END
         )
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
$function$;

-- 审查修复④：首次复制要并发安全。
-- 两个标签页同时首次打开配置页时，原来会双双查不到副本、双双 INSERT，
-- 其中一个必然撞唯一索引报错。改成先让唯一索引裁决，再读回同一份。
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
     AND t.source_template_id = v_ref.id
   LIMIT 1;

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
    ON CONFLICT (root_manager_id, source_template_id)
      WHERE root_manager_id IS NOT NULL
      DO NOTHING
    RETURNING id INTO v_own_id;

    IF v_own_id IS NULL THEN
      SELECT t.id INTO v_own_id
        FROM public.diet_map_templates t
       WHERE t.root_manager_id = v_root
         AND t.source_template_id = v_ref.id
       LIMIT 1;
    END IF;

    IF v_own_id IS NULL THEN
      RAISE EXCEPTION '本店的导图版本正在创建中，请稍后重新打开这个页面' USING ERRCODE = '40001';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'granted', true,
    'root_manager_id', v_root,
    'template_id', v_own_id,
    'reference_template_id', v_ref.id
  );
END;
$function$;