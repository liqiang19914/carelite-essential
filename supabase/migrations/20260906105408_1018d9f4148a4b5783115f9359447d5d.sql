-- 商户级称重海报字体大小设置：按企业根一行，控制客户称重海报导出图的字号档位
CREATE TABLE IF NOT EXISTS public.merchant_poster_font_settings (
  root_manager_id uuid PRIMARY KEY REFERENCES public.managers(id) ON DELETE CASCADE,
  poster_font_scale text NOT NULL DEFAULT 'normal'
    CHECK (poster_font_scale IN ('normal','large','xlarge')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

COMMENT ON TABLE public.merchant_poster_font_settings IS
  '商户级称重海报字体大小设置：root_manager_id 按企业根一行；normal=正常（基线），large=大（约 ×1.1），xlarge=超大（约 ×1.3）';
COMMENT ON COLUMN public.merchant_poster_font_settings.poster_font_scale IS
  '称重海报导出图字号档位；只影响称重海报图片（含转发卡片封面，因其自海报图裁剪），不影响 App 页面、体成分对比海报或导图海报';

ALTER TABLE public.merchant_poster_font_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.merchant_poster_font_settings FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_poster_font_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_poster_font_settings TO service_role;

CREATE OR REPLACE FUNCTION public.get_merchant_poster_font_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_row public.merchant_poster_font_settings%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.is_active_enterprise_content_member(v_uid) THEN
    RAISE EXCEPTION '所属企业当前不可配置，请联系企业负责人或平台处理' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);

  SELECT * INTO v_row
  FROM public.merchant_poster_font_settings
  WHERE root_manager_id = v_root;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('poster_font_scale', 'normal');
  END IF;

  RETURN jsonb_build_object('poster_font_scale', v_row.poster_font_scale);
END;
$function$;

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
  IF p_poster_font_scale IS NULL OR p_poster_font_scale NOT IN ('normal','large','xlarge') THEN
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

CREATE OR REPLACE FUNCTION public.get_public_poster_font_scale(p_root_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row public.merchant_poster_font_settings%ROWTYPE;
BEGIN
  IF p_root_manager_id IS NULL
     OR NOT public.is_public_enterprise_content_root(p_root_manager_id) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_poster_font_settings
  WHERE root_manager_id = p_root_manager_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('poster_font_scale', 'normal');
  END IF;

  RETURN jsonb_build_object('poster_font_scale', v_row.poster_font_scale);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_merchant_poster_font_settings() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_merchant_poster_font_settings() TO authenticated;
REVOKE ALL ON FUNCTION public.save_merchant_poster_font_settings(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_merchant_poster_font_settings(text) TO authenticated;
REVOKE ALL ON FUNCTION public.get_public_poster_font_scale(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_poster_font_scale(uuid) TO anon, authenticated;