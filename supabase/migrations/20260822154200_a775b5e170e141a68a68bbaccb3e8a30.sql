-- 243：平台 OEM 商户列表排除系统预置健管师（只显示真实商户与平台主程序）
CREATE OR REPLACE FUNCTION public.admin_list_manager_oem_configs()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '仅平台管理员可访问' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(t) ORDER BY t.created_at DESC), '[]'::jsonb)
    INTO v_result
  FROM (
    SELECT
      m.id                                 AS manager_id,
      p.nickname                           AS manager_nickname,
      p.phone                              AS manager_phone,
      m.certification_status               AS certification_status,
      COALESCE(mm.is_enabled, false)       AS is_enabled,
      mm.app_id                            AS app_id,
      (mm.app_secret IS NOT NULL AND length(mm.app_secret) > 0) AS has_app_secret,
      (mm.upload_key IS NOT NULL AND length(mm.upload_key) > 0) AS has_upload_key,
      mm.business_domain                   AS business_domain,
      mm.target_path                       AS target_path,
      mm.app_name                          AS app_name,
      mm.brand_name                        AS brand_name,
      mm.brand_logo_url                    AS brand_logo_url,
      mm.updated_at                        AS updated_at,
      mm.updated_by                        AS updated_by_id,
      up.nickname                          AS updated_by_nickname,
      m.created_at                         AS created_at
    FROM public.managers m
    JOIN public.profiles p ON p.id = m.id
    LEFT JOIN public.manager_miniprograms mm ON mm.manager_id = m.id
    LEFT JOIN public.profiles up ON up.id = mm.updated_by
    WHERE m.is_system_default IS DISTINCT FROM true
  ) t;

  RETURN v_result;
END;
$function$;

-- 243：客户「申请入驻」商户下拉排除系统预置健管师
CREATE OR REPLACE FUNCTION public.list_store_merchants_open()
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_items JSON;
BEGIN
  SELECT json_agg(t) INTO v_items
  FROM (
    SELECT m.id, m.business_name, m.partner_card_display_name,
           m.partner_card_avatar_url, m.company_name
    FROM public.managers m
    WHERE m.certification_status = 'approved'
      AND m.is_system_default IS DISTINCT FROM true
      AND public._store_module_on(m.id)
    ORDER BY m.created_at DESC
    LIMIT 100
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;