-- ── 统一商户根判定：企业主（活跃企业 owner）或 legacy 独立商户；员工、系统预置、平台根都不算 ──
CREATE OR REPLACE FUNCTION public.is_merchant_root(p_uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles p
    LEFT JOIN public.managers m ON m.id = p.id
    LEFT JOIN public.enterprises e ON e.id = p.enterprise_id
    WHERE p.id = p_uid
      AND p.role = 'manager'
      AND COALESCE(m.is_system_default, false) = false
      AND COALESCE(m.is_platform_root, false) = false
      AND (
        (e.id IS NOT NULL AND e.status = 'active' AND e.owner_profile_id = p.id)
        OR (e.id IS NULL AND p.parent_manager_id IS NULL)
      )
  );
$function$;

GRANT EXECUTE ON FUNCTION public.is_merchant_root(uuid) TO authenticated, anon, service_role;

-- ── 统一商户枚举接口：平台后台所有「按商户」的列表都从这里取根商户 ──
CREATE OR REPLACE FUNCTION public.admin_list_merchant_roots()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '仅平台管理员可访问' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT
      m.id AS manager_id,
      p.nickname,
      p.phone,
      m.business_name,
      m.company_name,
      m.short_code,
      m.brand_slug,
      m.created_at,
      e.id AS enterprise_id,
      e.name AS enterprise_name
    FROM public.managers m
    JOIN public.profiles p ON p.id = m.id
    LEFT JOIN public.enterprises e ON e.id = p.enterprise_id
    WHERE public.is_merchant_root(m.id)
  ) r;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_list_merchant_roots() TO authenticated, anon, service_role;

-- ── OEM 配置列表：只认商户根（员工不再被误列为 OEM 商户包） ──
DROP FUNCTION IF EXISTS public.admin_list_manager_oem_configs();

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
      m.created_at                         AS created_at,
      e.name                               AS enterprise_name
    FROM public.managers m
    JOIN public.profiles p ON p.id = m.id
    LEFT JOIN public.manager_miniprograms mm ON mm.manager_id = m.id
    LEFT JOIN public.profiles up ON up.id = mm.updated_by
    LEFT JOIN public.enterprises e ON e.id = p.enterprise_id
    WHERE public.is_merchant_root(m.id)
  ) t;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_list_manager_oem_configs() TO authenticated, anon, service_role;

-- ── 短信通道列表：只列商户根（员工误配的旧行只隐藏不删除） ──
DROP FUNCTION IF EXISTS public.admin_list_sms_configs();

CREATE OR REPLACE FUNCTION public.admin_list_sms_configs()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT c.id,
           c.root_manager_id,
           c.provider,
           CASE
             WHEN c.access_key_id IS NULL OR c.access_key_id = '' THEN NULL
             WHEN char_length(c.access_key_id) <= 6 THEN '******'
             ELSE left(c.access_key_id, 4) || '****' || right(c.access_key_id, 4)
           END AS access_key_id_masked,
           (c.access_key_secret IS NOT NULL AND c.access_key_secret <> '') AS has_access_key_secret,
           c.sign_name,
           c.template_code,
           c.code_expiry,
           c.tencent_sdk_app_id,
           c.config_revision,
           c.status,
           c.review_note,
           c.created_at,
           c.updated_at,
           COALESCE(NULLIF(m.business_name, ''), NULLIF(m.company_name, ''), m.id::text) AS merchant_name
    FROM public.manager_sms_configs c
    JOIN public.managers m ON m.id = c.root_manager_id
    WHERE public.is_merchant_root(c.root_manager_id)
  ) r;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_list_sms_configs() TO authenticated, anon, service_role;

-- ── 客户「申请入驻」商户下拉：只列商户根 ──
DROP FUNCTION IF EXISTS public.list_store_merchants_open();

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
      AND public._store_module_on(m.id)
      AND public.is_merchant_root(m.id)
    ORDER BY m.created_at DESC
    LIMIT 100
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;

GRANT EXECUTE ON FUNCTION public.list_store_merchants_open() TO authenticated, anon, service_role;