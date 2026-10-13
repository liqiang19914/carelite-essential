-- 档案授权模块商户级显示设置：root_manager_id 按企业根一行；默认隐藏（false）。
-- 隐藏时客户端不显示授权卡片、默认补写也跳过，商户数据全部可见。
CREATE TABLE IF NOT EXISTS public.merchant_record_auth_settings (
  root_manager_id uuid PRIMARY KEY REFERENCES public.managers(id) ON DELETE CASCADE,
  show_record_auth_module boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

COMMENT ON TABLE public.merchant_record_auth_settings IS
  '档案授权模块商户级显示设置：默认隐藏（false）；仅企业超级管理员可改';
COMMENT ON COLUMN public.merchant_record_auth_settings.show_record_auth_module IS
  'true 时客户档案管理页显示授权卡片、可自行开关授权；false 时隐藏且所有授权保持开启永久';

ALTER TABLE public.merchant_record_auth_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.merchant_record_auth_settings FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_record_auth_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_record_auth_settings TO service_role;

-- 共享判定：无授权行 = 默认已授权（新绑定/未打开过档案页的客户默认可见）；
-- 有行则按显式选择：is_active 且未过期才放行（关闭与过期仍拦截）。
CREATE OR REPLACE FUNCTION public.record_is_authorized(p_record_id uuid, p_manager_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT COALESCE((
    SELECT ra.is_active = true
       AND (ra.expires_at IS NULL OR ra.expires_at > now())
    FROM public.record_authorizations ra
    WHERE ra.record_id = p_record_id
      AND ra.manager_id = p_manager_id
    LIMIT 1
  ), true);
$function$;

REVOKE ALL ON FUNCTION public.record_is_authorized(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_is_authorized(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_merchant_record_auth_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_row public.merchant_record_auth_settings%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RAISE EXCEPTION '仅企业超级管理员可配置档案授权模块' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_record_auth_settings
  WHERE root_manager_id = v_root;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('show_record_auth_module', false);
  END IF;

  RETURN jsonb_build_object('show_record_auth_module', v_row.show_record_auth_module);
END;
$function$;

CREATE OR REPLACE FUNCTION public.save_merchant_record_auth_settings(
  p_show_record_auth_module boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_show boolean := COALESCE(p_show_record_auth_module, false);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RAISE EXCEPTION '仅企业超级管理员可配置档案授权模块' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.merchant_record_auth_settings
    (root_manager_id, show_record_auth_module, updated_by, updated_at)
  VALUES (v_root, v_show, v_uid, now())
  ON CONFLICT (root_manager_id) DO UPDATE
    SET show_record_auth_module = EXCLUDED.show_record_auth_module,
        updated_by = v_uid,
        updated_at = now();

  -- 保存隐藏时，同一事务内把该企业根下全部 active 客户关系的授权
  -- 幂等回填为开启 + 永久（manager_id 取关系自身值，不统一写根账号）。
  -- 回填失败整次保存回滚，不会出现「开关已隐藏但回填没完成」的部分状态。
  IF v_show = false THEN
    WITH rel AS (
      SELECT cr.client_id, cr.manager_id
      FROM public.client_relations cr
      WHERE cr.status = 'active'
        AND (
          cr.root_manager_id = v_root
          OR (cr.root_manager_id IS NULL AND cr.manager_id IN (
            SELECT v_root AS mid
            UNION
            SELECT mp.id FROM public.profiles mp
            WHERE mp.parent_manager_id = v_root AND mp.role = 'manager'
          ))
        )
    )
    INSERT INTO public.record_authorizations (record_id, manager_id, granted_at, expires_at, is_active)
    SELECT hr.id, rel.manager_id, now(), NULL, true
    FROM rel
    JOIN public.health_records hr ON hr.user_id = rel.client_id
    ON CONFLICT (record_id, manager_id) DO UPDATE
      SET is_active = true,
          expires_at = NULL;
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_public_record_auth_settings(p_root_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row public.merchant_record_auth_settings%ROWTYPE;
BEGIN
  IF p_root_manager_id IS NULL
     OR NOT public.is_public_enterprise_content_root(p_root_manager_id) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_record_auth_settings
  WHERE root_manager_id = p_root_manager_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('show_record_auth_module', false);
  END IF;

  RETURN jsonb_build_object('show_record_auth_module', v_row.show_record_auth_module);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_merchant_record_auth_settings() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_merchant_record_auth_settings() TO authenticated;
REVOKE ALL ON FUNCTION public.save_merchant_record_auth_settings(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_merchant_record_auth_settings(boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.get_public_record_auth_settings(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_record_auth_settings(uuid) TO anon, authenticated;