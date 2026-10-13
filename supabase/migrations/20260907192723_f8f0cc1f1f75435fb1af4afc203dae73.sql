-- 455/456：publish_shop_config 函数体扩列（签名不变，无需重建授权）
CREATE OR REPLACE FUNCTION public.publish_shop_config(p_root_manager_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_draft jsonb;
  v_nav jsonb;
  v_custom jsonb;
  v_me jsonb;
  v_review_nav jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再发布装修' USING ERRCODE = '28000';
  END IF;

  IF public.is_admin(v_uid) THEN
    v_root := p_root_manager_id;
    IF v_root IS NULL OR NOT EXISTS (SELECT 1 FROM public.managers WHERE id = v_root) THEN
      RAISE EXCEPTION '请选择有效企业' USING ERRCODE = '22023';
    END IF;
  ELSE
    IF NOT public.is_active_enterprise_content_member(v_uid) THEN
      RAISE EXCEPTION '所属企业当前不可发布装修，请联系企业负责人或平台处理' USING ERRCODE = '42501';
    END IF;
    v_root := public.get_enterprise_root_manager_id(v_uid);
  END IF;

  SELECT draft_pages, draft_navigation, draft_custom_pages, draft_me_page, draft_review_navigation
    INTO v_draft, v_nav, v_custom, v_me, v_review_nav
    FROM public.merchant_shop_configs
    WHERE root_manager_id = v_root;

  v_draft := public.validate_shop_pages(COALESCE(v_draft, '{}'::jsonb));
  v_nav := public.validate_shell_navigation(COALESCE(v_nav, '[]'::jsonb));
  v_custom := public.validate_custom_pages(COALESCE(v_custom, '[]'::jsonb));
  v_me := public.validate_me_page(COALESCE(v_me, '[]'::jsonb));
  v_review_nav := public.validate_shell_navigation(COALESCE(v_review_nav, '[]'::jsonb));

  INSERT INTO public.merchant_shop_configs
    (root_manager_id, draft_pages, published_pages,
     draft_navigation, published_navigation,
     draft_custom_pages, published_custom_pages,
     draft_me_page, published_me_page,
     draft_review_navigation, published_review_navigation,
     published_at, created_by, updated_by)
  VALUES (v_root, v_draft, v_draft, v_nav, v_nav, v_custom, v_custom, v_me, v_me,
          v_review_nav, v_review_nav, now(), v_uid, v_uid)
  ON CONFLICT (root_manager_id) DO UPDATE
    SET published_pages = EXCLUDED.published_pages,
        published_navigation = EXCLUDED.published_navigation,
        published_custom_pages = EXCLUDED.published_custom_pages,
        published_me_page = EXCLUDED.published_me_page,
        published_review_navigation = EXCLUDED.published_review_navigation,
        published_at = EXCLUDED.published_at,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object('success', true, 'root_manager_id', v_root, 'published_at', now());
END;
$function$;