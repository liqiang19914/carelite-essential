-- 绑定接口兼容新 5 位数字码与存量 4 位字母数字码（4-12 位字母数字）
CREATE OR REPLACE FUNCTION public.bind_promoter_by_code(p_short_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid   uuid := auth.uid();
  v_code  public.promotion_codes;
  v_rule  public.promotion_rules;
  v_bind  public.promoter_bindings;
  v_code_raw text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_uid AND role = 'user' AND is_disabled = false) THEN
    RAISE EXCEPTION '只有客户可以绑定推广关系' USING ERRCODE = '42501';
  END IF;

  v_code_raw := btrim(COALESCE(p_short_code, ''));
  IF v_code_raw !~ '^[A-Za-z0-9]{4,12}$' THEN
    RAISE EXCEPTION '推广码无效' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_code FROM public.promotion_codes
  WHERE short_code = v_code_raw AND is_active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION '推广码无效或已停用' USING ERRCODE = '22023';
  END IF;
  IF NOT public.is_merchant_root(v_code.enterprise_root_id) THEN
    RAISE EXCEPTION '推广码无效' USING ERRCODE = '22023';
  END IF;
  IF v_code.promoter_id = v_uid THEN
    RAISE EXCEPTION '不能绑定自己的推广码' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_bind FROM public.promoter_bindings
  WHERE enterprise_root_id = v_code.enterprise_root_id AND client_id = v_uid
  FOR UPDATE;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'already_bound', true,
      'promoter_id', v_bind.promoter_id,
      'same_promoter', v_bind.promoter_id = v_code.promoter_id,
      'points_granted', false
    );
  END IF;

  SELECT * INTO v_rule FROM public.promotion_rules
  WHERE enterprise_root_id = v_code.enterprise_root_id;

  INSERT INTO public.promoter_bindings (enterprise_root_id, promoter_id, client_id)
  VALUES (v_code.enterprise_root_id, v_code.promoter_id, v_uid)
  RETURNING * INTO v_bind;

  IF v_rule.id IS NOT NULL AND (COALESCE(v_rule.inviter_points, 0) > 0 OR COALESCE(v_rule.invitee_points, 0) > 0) THEN
    IF COALESCE(v_rule.inviter_points, 0) > 0 THEN
      PERFORM public._post_points_delta(
        v_bind.promoter_id, v_rule.inviter_points,
        'promotion', '新客户绑定推广关系奖励',
        'promotion:inviter:' || v_bind.id::text, 'binding', v_bind.id, v_uid
      );
    END IF;
    IF COALESCE(v_rule.invitee_points, 0) > 0 THEN
      PERFORM public._post_points_delta(
        v_uid, v_rule.invitee_points,
        'promotion', '绑定推广关系奖励',
        'promotion:invitee:' || v_bind.id::text, 'binding', v_bind.id, v_uid
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'already_bound', false,
    'promoter_id', v_bind.promoter_id,
    'same_promoter', true,
    'points_granted', true
  );
END;
$function$;