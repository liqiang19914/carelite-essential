-- 问卷公开可见策略：修复分享链接匿名打不开的根因（surveys 表此前没有匿名 SELECT 策略）
DROP POLICY IF EXISTS "Anyone can view active surveys" ON public.surveys;
CREATE POLICY "Anyone can view active surveys" ON public.surveys
FOR SELECT TO anon, authenticated
USING (status = 'active'::survey_status);

-- 公开问卷一次性接口：问卷 + 题目 + 商户品牌上下文
CREATE OR REPLACE FUNCTION public.get_public_survey(p_share_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_survey public.surveys%ROWTYPE;
  v_root uuid;
  v_brand jsonb;
  v_questions jsonb;
BEGIN
  IF p_share_code IS NULL OR btrim(p_share_code) = '' THEN
    RAISE EXCEPTION '分享码无效' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_survey
  FROM public.surveys
  WHERE share_code = p_share_code
  LIMIT 1;

  IF v_survey.id IS NULL THEN
    RAISE EXCEPTION '问卷不存在或已失效' USING ERRCODE = '22023';
  END IF;

  IF v_survey.status <> 'active' THEN
    RAISE EXCEPTION '该问卷已关闭' USING ERRCODE = '22023';
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'id', q.id,
      'questionType', q.question_type,
      'title', q.title,
      'description', q.description,
      'options', COALESCE(q.options, '[]'::jsonb),
      'isRequired', q.is_required,
      'displayOrder', q.display_order
    ) ORDER BY q.display_order
  ) INTO v_questions
  FROM public.survey_questions q
  WHERE q.survey_id = v_survey.id;

  SELECT public.get_enterprise_root_manager_id(v_survey.manager_id) INTO v_root;

  SELECT jsonb_build_object(
    'slug', NULLIF(btrim(COALESCE(m.brand_slug, m.short_code, '')), ''),
    'name', COALESCE(NULLIF(btrim(m.company_name), ''), NULLIF(btrim(m.business_name), ''), ''),
    'primaryColor', NULLIF(btrim(COALESCE(m.brand_primary_color, '')), '')
  ) INTO v_brand
  FROM public.managers m
  WHERE m.id = v_root;

  IF v_brand IS NULL THEN
    v_brand := '{}'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'survey', jsonb_build_object(
      'id', v_survey.id,
      'title', v_survey.title,
      'description', COALESCE(v_survey.description, ''),
      'status', v_survey.status::text,
      'shareCode', v_survey.share_code
    ),
    'questions', COALESCE(v_questions, '[]'::jsonb),
    'brand', v_brand
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_survey(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_survey(text) TO anon, authenticated;