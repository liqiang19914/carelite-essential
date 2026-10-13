CREATE OR REPLACE FUNCTION public.save_help_faq(
  p_audience   text,
  p_question   text,
  p_answer     text,
  p_sort_order integer DEFAULT 0,
  p_id         uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid      uuid := auth.uid();
  v_is_admin boolean;
  v_root     uuid;
  v_scope    text;
  v_id       uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  IF p_audience IS NULL OR p_audience NOT IN ('user','manager') THEN
    RAISE EXCEPTION '非法受众类型' USING ERRCODE = '22023';
  END IF;
  IF btrim(p_question) = '' OR btrim(p_answer) = '' THEN
    RAISE EXCEPTION '问题和答案都不能为空' USING ERRCODE = '22023';
  END IF;

  SELECT public.is_admin(v_uid) INTO v_is_admin;

  IF v_is_admin THEN
    v_scope := 'platform';
    v_root  := NULL;
  ELSE
    SELECT (p.parent_manager_id IS NULL OR p.sub_role = 'admin') INTO v_is_admin
    FROM public.profiles p
    WHERE p.id = v_uid AND p.role = 'manager';

    IF v_is_admin IS NOT TRUE THEN
      RAISE EXCEPTION '仅企业管理员可修改帮助内容' USING ERRCODE = '42501';
    END IF;
    IF p_audience <> 'user' THEN
      RAISE EXCEPTION '商户只能维护面向客户的帮助' USING ERRCODE = '42501';
    END IF;

    SELECT CASE WHEN p.parent_manager_id IS NULL THEN p.id ELSE p.parent_manager_id END
      INTO v_root
      FROM public.profiles p
      WHERE p.id = v_uid;
    v_scope := 'merchant';
  END IF;

  IF p_id IS NOT NULL THEN
    UPDATE public.help_faqs
      SET audience   = p_audience,
          question   = btrim(p_question),
          answer     = btrim(p_answer),
          sort_order = COALESCE(p_sort_order, 0),
          updated_at = now()
      WHERE id = p_id
        AND scope = v_scope
        AND root_manager_id IS NOT DISTINCT FROM v_root
      RETURNING id INTO v_id;

    IF v_id IS NULL THEN
      RAISE EXCEPTION '帮助条目不存在或无权修改' USING ERRCODE = '22023';
    END IF;
  ELSE
    INSERT INTO public.help_faqs (scope, root_manager_id, audience, question, answer, sort_order)
    VALUES (v_scope, v_root, p_audience, btrim(p_question), btrim(p_answer), COALESCE(p_sort_order, 0))
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object('id', v_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.save_help_faq(text, text, text, integer, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_help_faq(text, text, text, integer, uuid) TO authenticated;