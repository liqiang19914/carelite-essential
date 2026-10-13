-- 455：save_shop_config_draft 扩签名（审核菜单草稿 + 启用开关）；按惯例先 DROP 旧签名再重建并重发授权
DROP FUNCTION IF EXISTS public.save_shop_config_draft(jsonb, uuid, jsonb, jsonb, jsonb);

CREATE OR REPLACE FUNCTION public.save_shop_config_draft(
  p_pages jsonb,
  p_root_manager_id uuid DEFAULT NULL::uuid,
  p_navigation jsonb DEFAULT NULL::jsonb,
  p_custom_pages jsonb DEFAULT NULL::jsonb,
  p_me_page jsonb DEFAULT NULL::jsonb,
  p_review_navigation jsonb DEFAULT NULL::jsonb,
  p_review_enabled boolean DEFAULT NULL::boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_row public.merchant_shop_configs%ROWTYPE;
  v_normalized jsonb;
  v_nav jsonb;
  v_custom jsonb;
  v_me jsonb;
  v_review_nav jsonb;
  v_review_enabled boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再保存装修' USING ERRCODE = '28000';
  END IF;

  IF public.is_admin(v_uid) THEN
    v_root := p_root_manager_id;
    IF v_root IS NULL OR NOT EXISTS (SELECT 1 FROM public.managers WHERE id = v_root) THEN
      RAISE EXCEPTION '请选择有效企业' USING ERRCODE = '22023';
    END IF;
  ELSE
    IF NOT public.is_active_enterprise_content_member(v_uid) THEN
      RAISE EXCEPTION '所属企业当前不可保存装修，请联系企业负责人或平台处理' USING ERRCODE = '42501';
    END IF;
    v_root := public.get_enterprise_root_manager_id(v_uid);
  END IF;

  SELECT * INTO v_row FROM public.merchant_shop_configs WHERE root_manager_id = v_root;
  v_normalized := public.validate_shop_pages(p_pages);
  v_nav := public.validate_shell_navigation(COALESCE(p_navigation, COALESCE(v_row.draft_navigation, '[]'::jsonb)));
  v_custom := public.validate_custom_pages(COALESCE(p_custom_pages, COALESCE(v_row.draft_custom_pages, '[]'::jsonb)));
  v_me := public.validate_me_page(COALESCE(p_me_page, COALESCE(v_row.draft_me_page, '[]'::jsonb)));
  v_review_nav := public.validate_shell_navigation(COALESCE(p_review_navigation, COALESCE(v_row.draft_review_navigation, '[]'::jsonb)));
  v_review_enabled := COALESCE(p_review_enabled, v_row.review_menu_enabled, false);

  INSERT INTO public.merchant_shop_configs
    (root_manager_id, draft_pages, draft_navigation, draft_custom_pages, draft_me_page,
     draft_review_navigation, review_menu_enabled, created_by, updated_by)
  VALUES (v_root, v_normalized, v_nav, v_custom, v_me, v_review_nav, v_review_enabled, v_uid, v_uid)
  ON CONFLICT (root_manager_id) DO UPDATE
    SET draft_pages = EXCLUDED.draft_pages,
        draft_navigation = EXCLUDED.draft_navigation,
        draft_custom_pages = EXCLUDED.draft_custom_pages,
        draft_me_page = EXCLUDED.draft_me_page,
        draft_review_navigation = EXCLUDED.draft_review_navigation,
        review_menu_enabled = EXCLUDED.review_menu_enabled,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object(
    'success', true,
    'root_manager_id', v_root,
    'draft_pages', v_normalized,
    'draft_navigation', v_nav,
    'draft_custom_pages', v_custom,
    'draft_me_page', v_me,
    'draft_review_navigation', v_review_nav,
    'review_menu_enabled', v_review_enabled
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.save_shop_config_draft(jsonb, uuid, jsonb, jsonb, jsonb, jsonb, boolean)
  TO authenticated, service_role;