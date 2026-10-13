-- feature 438：称重海报字体新增「超超大」档（×1.5）——CHECK 扩四档并收口固定约束名（两次 DROP IF EXISTS 兼容 436 自动命名与固定名，幂等可重放）；save RPC 白名单加 xxlarge，中文报错文案与授权结构保持不变
ALTER TABLE public.merchant_poster_font_settings
  DROP CONSTRAINT IF EXISTS merchant_poster_font_settings_poster_font_scale_check;
ALTER TABLE public.merchant_poster_font_settings
  DROP CONSTRAINT IF EXISTS merchant_poster_font_settings_scale_check;
ALTER TABLE public.merchant_poster_font_settings
  ADD CONSTRAINT merchant_poster_font_settings_scale_check
  CHECK (poster_font_scale IN ('normal','large','xlarge','xxlarge'));

COMMENT ON TABLE public.merchant_poster_font_settings IS
  '商户级称重海报字体大小设置：root_manager_id 按企业根一行；normal=正常（基线），large=大（约 ×1.1），xlarge=超大（约 ×1.3），xxlarge=超超大（约 ×1.5）';

CREATE OR REPLACE FUNCTION public.save_merchant_poster_font_settings(
  p_poster_font_scale text
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
    RAISE EXCEPTION '只有企业超级管理员可以修改称重海报字体大小' USING ERRCODE = '42501';
  END IF;
  IF p_poster_font_scale IS NULL OR p_poster_font_scale NOT IN ('normal','large','xlarge','xxlarge') THEN
    RAISE EXCEPTION '无效的称重海报字体档位' USING ERRCODE = '22023';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);

  INSERT INTO public.merchant_poster_font_settings
    (root_manager_id, poster_font_scale, updated_by, updated_at)
  VALUES (v_root, p_poster_font_scale, v_uid, now())
  ON CONFLICT (root_manager_id) DO UPDATE
    SET poster_font_scale = EXCLUDED.poster_font_scale,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.save_merchant_poster_font_settings(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_merchant_poster_font_settings(text) TO authenticated;