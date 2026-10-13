CREATE OR REPLACE FUNCTION public.list_public_enterprise_managers(p_manager_id uuid)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_root uuid;
  v_result json;
BEGIN
  IF p_manager_id IS NULL THEN
    RETURN '[]'::json;
  END IF;

  SELECT COALESCE(p.parent_manager_id, p.id) INTO v_root
  FROM public.profiles p
  WHERE p.id = p_manager_id;

  IF v_root IS NULL THEN
    RETURN '[]'::json;
  END IF;

  SELECT json_agg(
    json_build_object(
      'manager_id', m.id,
      'short_code', m.short_code,
      'display_name', COALESCE(NULLIF(m.partner_card_display_name, ''), ep.nickname, '健康管理师'),
      'avatar_url', COALESCE(NULLIF(m.digital_avatar_image_url, ''), NULLIF(m.partner_card_avatar_url, ''), NULLIF(ep.avatar_url, '')),
      'tagline', NULLIF(m.tagline, ''),
      'company_name', NULLIF(COALESCE(m.company_name, m.partner_card_company_name, m.business_name), ''),
      'is_recommended', COALESCE(m.is_recommended, false)
    )
    ORDER BY COALESCE(m.is_recommended, false) DESC, ep.created_at ASC
  ) INTO v_result
  FROM public.profiles ep
  JOIN public.managers m ON m.id = ep.id
  WHERE ep.parent_manager_id = v_root
    AND ep.role = 'manager'
    AND ep.sub_role = 'health_manager'
    AND ep.is_disabled = false
    AND COALESCE(m.is_example, false) = false;

  RETURN COALESCE(v_result, '[]'::json);
END;
$function$;