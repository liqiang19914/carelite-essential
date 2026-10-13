-- ============================================================================
-- 健康管理师 OEM 小程序：5 个 RPC
-- ============================================================================

-- ─── RPC 1: admin_list_manager_oem_configs ─────────────────────────────────
-- 列表用：返回安全摘要，不带 app_secret / upload_key 明文

CREATE OR REPLACE FUNCTION public.admin_list_manager_oem_configs()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
      mm.updated_at                        AS updated_at,
      mm.updated_by                        AS updated_by_id,
      up.nickname                          AS updated_by_nickname,
      m.created_at                         AS created_at
    FROM public.managers m
    JOIN public.profiles p ON p.id = m.id
    LEFT JOIN public.manager_miniprograms mm ON mm.manager_id = m.id
    LEFT JOIN public.profiles up ON up.id = mm.updated_by
  ) t;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_list_manager_oem_configs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_manager_oem_configs() TO authenticated;

-- ─── RPC 2: get_manager_oem_config ─────────────────────────────────────────
-- admin 可看任意；manager 仅自己；无 row 返回标准 disabled 对象

CREATE OR REPLACE FUNCTION public.get_manager_oem_config(p_manager_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_target uuid;
  v_is_admin boolean;
  v_row public.manager_miniprograms%ROWTYPE;
  v_manager_nickname text;
  v_manager_phone text;
  v_manager_cert text;
  v_updated_by_nickname text;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  v_is_admin := public.is_admin(v_caller);
  v_target := COALESCE(p_manager_id, v_caller);

  IF NOT v_is_admin AND v_target <> v_caller THEN
    RAISE EXCEPTION '无权访问该管理师配置' USING ERRCODE = '42501';
  END IF;

  SELECT p.nickname, p.phone, m.certification_status
    INTO v_manager_nickname, v_manager_phone, v_manager_cert
  FROM public.managers m
  JOIN public.profiles p ON p.id = m.id
  WHERE m.id = v_target;

  IF v_manager_nickname IS NULL THEN
    RAISE EXCEPTION '管理师不存在' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row FROM public.manager_miniprograms WHERE manager_id = v_target;

  IF v_row.manager_id IS NULL THEN
    RETURN jsonb_build_object(
      'manager_id',           v_target,
      'manager_nickname',     v_manager_nickname,
      'manager_phone',        v_manager_phone,
      'certification_status', v_manager_cert,
      'is_enabled',           false,
      'exists',               false,
      'app_name',             NULL,
      'app_id',               NULL,
      'app_secret',           NULL,
      'original_id',          NULL,
      'upload_key',           NULL,
      'version',              '1.0.0',
      'request_domain',       NULL,
      'socket_domain',        NULL,
      'upload_domain',        NULL,
      'download_domain',      NULL,
      'udp_domain',           NULL,
      'business_domain',      NULL,
      'target_path',          '/login',
      'updated_at',           NULL,
      'updated_by_id',        NULL,
      'updated_by_nickname',  NULL
    );
  END IF;

  SELECT nickname INTO v_updated_by_nickname FROM public.profiles WHERE id = v_row.updated_by;

  RETURN jsonb_build_object(
    'manager_id',           v_row.manager_id,
    'manager_nickname',     v_manager_nickname,
    'manager_phone',        v_manager_phone,
    'certification_status', v_manager_cert,
    'is_enabled',           v_row.is_enabled,
    'exists',               true,
    'app_name',             v_row.app_name,
    'app_id',               v_row.app_id,
    'app_secret',           v_row.app_secret,
    'original_id',          v_row.original_id,
    'upload_key',           v_row.upload_key,
    'version',              v_row.version,
    'request_domain',       v_row.request_domain,
    'socket_domain',        v_row.socket_domain,
    'upload_domain',        v_row.upload_domain,
    'download_domain',      v_row.download_domain,
    'udp_domain',           v_row.udp_domain,
    'business_domain',      v_row.business_domain,
    'target_path',          v_row.target_path,
    'updated_at',           v_row.updated_at,
    'updated_by_id',        v_row.updated_by,
    'updated_by_nickname',  v_updated_by_nickname
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_manager_oem_config(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_manager_oem_config(uuid) TO authenticated;

-- ─── RPC 3: admin_set_manager_oem_toggle ───────────────────────────────────
-- 仅 admin；开启时校验目标 manager certification_status='approved'

CREATE OR REPLACE FUNCTION public.admin_set_manager_oem_toggle(
  p_manager_id uuid,
  p_enabled    boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_cert text;
BEGIN
  IF NOT public.is_admin(v_caller) THEN
    RAISE EXCEPTION '仅平台管理员可操作' USING ERRCODE = '42501';
  END IF;

  SELECT certification_status INTO v_cert FROM public.managers WHERE id = p_manager_id;
  IF v_cert IS NULL THEN
    RAISE EXCEPTION '管理师不存在' USING ERRCODE = '22023';
  END IF;

  IF p_enabled AND v_cert <> 'approved' THEN
    RAISE EXCEPTION '仅已审核通过的管理师可开通 OEM 小程序' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.manager_miniprograms (manager_id, is_enabled, created_by, updated_by)
  VALUES (p_manager_id, p_enabled, v_caller, v_caller)
  ON CONFLICT (manager_id) DO UPDATE
  SET is_enabled = EXCLUDED.is_enabled,
      updated_by = v_caller;

  RETURN jsonb_build_object('success', true, 'manager_id', p_manager_id, 'is_enabled', p_enabled);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_set_manager_oem_toggle(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_manager_oem_toggle(uuid, boolean) TO authenticated;

-- ─── RPC 4: admin_save_manager_oem_config ──────────────────────────────────
-- admin 写入；JSON 字段白名单；不允许改 is_enabled；UPSERT 模式（admin 可先填后开关）

CREATE OR REPLACE FUNCTION public.admin_save_manager_oem_config(
  p_manager_id uuid,
  p_config     jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_cert text;
BEGIN
  IF NOT public.is_admin(v_caller) THEN
    RAISE EXCEPTION '仅平台管理员可操作' USING ERRCODE = '42501';
  END IF;

  SELECT certification_status INTO v_cert FROM public.managers WHERE id = p_manager_id;
  IF v_cert IS NULL THEN
    RAISE EXCEPTION '管理师不存在' USING ERRCODE = '22023';
  END IF;

  -- Ensure row exists (without flipping is_enabled if it already exists)
  INSERT INTO public.manager_miniprograms (manager_id, is_enabled, created_by, updated_by)
  VALUES (p_manager_id, false, v_caller, v_caller)
  ON CONFLICT (manager_id) DO NOTHING;

  PERFORM public._manager_miniprograms_apply_config(p_manager_id, p_config);

  RETURN jsonb_build_object('success', true, 'manager_id', p_manager_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_save_manager_oem_config(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_save_manager_oem_config(uuid, jsonb) TO authenticated;

-- ─── RPC 5: manager_save_my_oem_config ─────────────────────────────────────
-- 管理师自己保存；必须 approved + is_enabled=true

CREATE OR REPLACE FUNCTION public.manager_save_my_oem_config(p_config jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_cert text;
  v_enabled boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT certification_status INTO v_cert FROM public.managers WHERE id = v_caller;
  IF v_cert IS NULL THEN
    RAISE EXCEPTION '当前账号不是管理师' USING ERRCODE = '42501';
  END IF;
  IF v_cert <> 'approved' THEN
    RAISE EXCEPTION '账号未审核通过，无法保存 OEM 配置' USING ERRCODE = '42501';
  END IF;

  SELECT is_enabled INTO v_enabled FROM public.manager_miniprograms WHERE manager_id = v_caller;
  IF v_enabled IS NULL THEN
    RAISE EXCEPTION '尚未开通 OEM 小程序，请联系平台管理员' USING ERRCODE = '42501';
  END IF;
  IF NOT v_enabled THEN
    RAISE EXCEPTION 'OEM 小程序已关闭，无法保存' USING ERRCODE = '42501';
  END IF;

  PERFORM public._manager_miniprograms_apply_config(v_caller, p_config);

  RETURN jsonb_build_object('success', true, 'manager_id', v_caller);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.manager_save_my_oem_config(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.manager_save_my_oem_config(jsonb) TO authenticated;