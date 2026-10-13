-- 商户级客户 App 字体大小设置：按企业根一行，控制客户端全站字体档位
CREATE TABLE IF NOT EXISTS public.merchant_font_size_settings (
  root_manager_id uuid PRIMARY KEY REFERENCES public.managers(id) ON DELETE CASCADE,
  font_scale text NOT NULL DEFAULT 'large'
    CHECK (font_scale IN ('standard','large','xl')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

COMMENT ON TABLE public.merchant_font_size_settings IS
  '商户级客户 App 字体大小设置：root_manager_id 按企业根一行；standard=标准，large=大，xl=超大，默认 large';
COMMENT ON COLUMN public.merchant_font_size_settings.font_scale IS
  '客户端 App 字体档位；未自选的客户跟随商户默认值';

ALTER TABLE public.merchant_font_size_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.merchant_font_size_settings FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_font_size_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_font_size_settings TO service_role;

CREATE OR REPLACE FUNCTION public.get_merchant_font_size_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_row public.merchant_font_size_settings%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.is_active_enterprise_content_member(v_uid) THEN
    RAISE EXCEPTION '所属企业当前不可配置，请联系企业负责人或平台处理' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);

  SELECT * INTO v_row
  FROM public.merchant_font_size_settings
  WHERE root_manager_id = v_root;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('font_scale', 'large');
  END IF;

  RETURN jsonb_build_object('font_scale', v_row.font_scale);
END;
$function$;

CREATE OR REPLACE FUNCTION public.save_merchant_font_size_settings(
  p_font_scale text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RAISE EXCEPTION '只有企业超级管理员可以修改字体大小设置' USING ERRCODE = '42501';
  END IF;
  IF p_font_scale IS NULL OR p_font_scale NOT IN ('standard','large','xl') THEN
    RAISE EXCEPTION '无效的字体大小档位' USING ERRCODE = '22023';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);

  INSERT INTO public.merchant_font_size_settings
    (root_manager_id, font_scale, updated_by, updated_at)
  VALUES (v_root, p_font_scale, v_uid, now())
  ON CONFLICT (root_manager_id) DO UPDATE
    SET font_scale = EXCLUDED.font_scale,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object('success', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_public_font_size_settings(p_root_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row public.merchant_font_size_settings%ROWTYPE;
BEGIN
  IF p_root_manager_id IS NULL
     OR NOT public.is_public_enterprise_content_root(p_root_manager_id) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_font_size_settings
  WHERE root_manager_id = p_root_manager_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('font_scale', 'large');
  END IF;

  RETURN jsonb_build_object('font_scale', v_row.font_scale);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_merchant_font_size_settings() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_merchant_font_size_settings() TO authenticated;
REVOKE ALL ON FUNCTION public.save_merchant_font_size_settings(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_merchant_font_size_settings(text) TO authenticated;
REVOKE ALL ON FUNCTION public.get_public_font_size_settings(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_font_size_settings(uuid) TO anon, authenticated;