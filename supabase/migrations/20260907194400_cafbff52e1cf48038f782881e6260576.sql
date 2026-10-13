-- 455：get_my_shop_config 返回审核菜单草稿/发布与启用开关（签名不变，无需重建授权）
CREATE OR REPLACE FUNCTION public.get_my_shop_config(p_root_manager_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_row public.merchant_shop_configs%ROWTYPE;
  v_draft jsonb;
  v_published jsonb;
  v_draft_nav jsonb;
  v_published_nav jsonb;
  v_draft_custom jsonb;
  v_published_custom jsonb;
  v_draft_me jsonb;
  v_published_me jsonb;
  v_draft_review_nav jsonb;
  v_published_review_nav jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再管理店铺装修' USING ERRCODE = '28000';
  END IF;

  IF public.is_admin(v_uid) THEN
    v_root := p_root_manager_id;
    IF v_root IS NULL OR NOT EXISTS (SELECT 1 FROM public.managers WHERE id = v_root) THEN
      RAISE EXCEPTION '请选择有效企业' USING ERRCODE = '22023';
    END IF;
  ELSE
    IF NOT public.is_active_enterprise_content_member(v_uid) THEN
      RAISE EXCEPTION '所属企业当前不可使用店铺装修，请联系企业负责人或平台处理' USING ERRCODE = '42501';
    END IF;
    v_root := public.get_enterprise_root_manager_id(v_uid);
  END IF;

  SELECT * INTO v_row FROM public.merchant_shop_configs WHERE root_manager_id = v_root;

  v_draft := public.validate_shop_pages(COALESCE(v_row.draft_pages, '{}'::jsonb));
  v_published := public.validate_shop_pages(COALESCE(v_row.published_pages, '{}'::jsonb));
  v_draft_nav := public.validate_shell_navigation(COALESCE(v_row.draft_navigation, '[]'::jsonb));
  v_published_nav := public.validate_shell_navigation(COALESCE(v_row.published_navigation, '[]'::jsonb));
  v_draft_custom := public.validate_custom_pages(COALESCE(v_row.draft_custom_pages, '[]'::jsonb));
  v_published_custom := public.validate_custom_pages(COALESCE(v_row.published_custom_pages, '[]'::jsonb));
  v_draft_me := public.validate_me_page(COALESCE(v_row.draft_me_page, '[]'::jsonb));
  v_published_me := public.validate_me_page(COALESCE(v_row.published_me_page, '[]'::jsonb));
  v_draft_review_nav := public.validate_shell_navigation(COALESCE(v_row.draft_review_navigation, '[]'::jsonb));
  v_published_review_nav := public.validate_shell_navigation(COALESCE(v_row.published_review_navigation, '[]'::jsonb));

  RETURN jsonb_build_object(
    'root_manager_id', v_root,
    'draft_pages', v_draft,
    'published_pages', v_published,
    'draft_navigation', v_draft_nav,
    'published_navigation', v_published_nav,
    'draft_custom_pages', v_draft_custom,
    'published_custom_pages', v_published_custom,
    'draft_me_page', v_draft_me,
    'published_me_page', v_published_me,
    'draft_review_navigation', v_draft_review_nav,
    'published_review_navigation', v_published_review_nav,
    'review_menu_enabled', COALESCE(v_row.review_menu_enabled, false),
    'published_at', v_row.published_at,
    'has_draft', (v_row.root_manager_id IS NOT NULL) AND (
        v_draft IS DISTINCT FROM v_published
        OR v_draft_nav IS DISTINCT FROM v_published_nav
        OR v_draft_custom IS DISTINCT FROM v_published_custom
        OR v_draft_me IS DISTINCT FROM v_published_me
        OR v_draft_review_nav IS DISTINCT FROM v_published_review_nav
      )
  );
END;
$function$;