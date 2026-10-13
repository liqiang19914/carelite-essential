-- managers 表没有 avatar_url 列，头像只从 profiles 取
CREATE OR REPLACE FUNCTION public.get_public_merchant_weighing_ai_manager(p_root_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row public.merchant_weighing_ai_settings%ROWTYPE;
  v_name text;
  v_avatar text;
BEGIN
  IF p_root_manager_id IS NULL
     OR NOT public.is_public_enterprise_content_root(p_root_manager_id) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_weighing_ai_settings
  WHERE root_manager_id = p_root_manager_id;

  IF NOT FOUND OR v_row.weighing_manager_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(m.partner_card_display_name, p.nickname, '健康管理师'),
         p.avatar_url
    INTO v_name, v_avatar
    FROM public.managers m
    LEFT JOIN public.profiles p ON p.id = m.id
    WHERE m.id = v_row.weighing_manager_id
      AND p.is_disabled IS NOT TRUE
      AND public.get_enterprise_root_manager_id(m.id) = p_root_manager_id;

  IF v_name IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'manager_id', v_row.weighing_manager_id,
    'display_name', v_name,
    'avatar_url', v_avatar
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_merchant_weighing_ai_manager(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_merchant_weighing_ai_manager(uuid) TO anon, authenticated;