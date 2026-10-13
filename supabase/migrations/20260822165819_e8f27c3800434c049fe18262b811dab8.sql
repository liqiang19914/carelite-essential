-- 247：企业名称一处修改、各端跟随显示
-- RPC 1: 读自己的企业信息（authenticated，无企业返回 null）
CREATE OR REPLACE FUNCTION public.get_my_enterprise_profile()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_enterprise_id uuid;
  v_name text;
BEGIN
  SELECT enterprise_id INTO v_enterprise_id FROM profiles WHERE id = auth.uid();
  IF v_enterprise_id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT name INTO v_name FROM enterprises WHERE id = v_enterprise_id;
  IF v_name IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('enterprise_id', v_enterprise_id, 'name', v_name);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_my_enterprise_profile() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_enterprise_profile() TO authenticated;

-- RPC 2: 企业主修改企业名称（原子更新企业名 + 条件联动对外品牌名）
CREATE OR REPLACE FUNCTION public.save_my_enterprise_name(p_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_enterprise_id uuid;
  v_old_name text;
  v_brand text;
  v_brand_followed boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION '企业名称不能为空' USING ERRCODE = '22023';
  END IF;
  IF length(btrim(p_name)) < 2 OR length(btrim(p_name)) > 40 THEN
    RAISE EXCEPTION '企业名称长度需在 2 到 40 个字之间' USING ERRCODE = '22023';
  END IF;

  SELECT enterprise_id INTO v_enterprise_id FROM profiles WHERE id = v_uid;
  IF v_enterprise_id IS NULL THEN
    RAISE EXCEPTION '您还没有企业，无法修改企业名称' USING ERRCODE = '42501';
  END IF;

  PERFORM 1 FROM enterprises WHERE id = v_enterprise_id AND owner_profile_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '仅企业主可修改企业名称' USING ERRCODE = '42501';
  END IF;

  SELECT name INTO v_old_name FROM enterprises WHERE id = v_enterprise_id;
  UPDATE enterprises SET name = btrim(p_name), updated_at = now() WHERE id = v_enterprise_id;

  -- 对外品牌名联动：仅当已有 OEM 配置、且品牌名未独立设置（为空或等于旧企业名）时跟随
  SELECT brand_name INTO v_brand FROM manager_miniprograms WHERE manager_id = v_uid FOR UPDATE;
  IF FOUND THEN
    IF v_brand IS NULL OR v_brand = '' OR v_brand = v_old_name THEN
      UPDATE manager_miniprograms SET brand_name = btrim(p_name) WHERE manager_id = v_uid;
      v_brand_followed := true;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'enterprise_id', v_enterprise_id,
    'name', btrim(p_name),
    'brand_followed', v_brand_followed
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.save_my_enterprise_name(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_my_enterprise_name(text) TO authenticated;

-- RPC 3: OEM 列表摘要补 enterprise_name（签名不变，保留 ACL）
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
    WHERE m.is_system_default IS DISTINCT FROM true
  ) t;

  RETURN v_result;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.admin_list_manager_oem_configs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_manager_oem_configs() TO authenticated;