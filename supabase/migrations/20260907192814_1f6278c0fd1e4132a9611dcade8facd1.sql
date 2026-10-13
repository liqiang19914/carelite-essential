-- 455/456：公开读 RPC 扩签名（p_review 审核态开关，默认 false 不影响既有调用）+ guest_chat_path/menu_mode
DROP FUNCTION IF EXISTS public.get_published_shop_config(uuid);
DROP FUNCTION IF EXISTS public.get_published_shop_config_for_root(uuid);

CREATE OR REPLACE FUNCTION public.get_published_shop_config(
  p_manager_id uuid,
  p_review boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_row public.merchant_shop_configs%ROWTYPE;
  v_nav jsonb;
  v_review_nav jsonb;
  v_menu_mode text := 'standard';
BEGIN
  v_root := public.get_enterprise_root_manager_id(p_manager_id);
  IF v_root IS NULL OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row FROM public.merchant_shop_configs WHERE root_manager_id = v_root;

  v_nav := public.validate_shell_navigation(COALESCE(v_row.published_navigation, '[]'::jsonb));
  IF COALESCE(p_review, false) AND COALESCE(v_row.review_menu_enabled, false) THEN
    v_review_nav := public.validate_shell_navigation(COALESCE(v_row.published_review_navigation, '[]'::jsonb));
    IF jsonb_array_length(v_review_nav) > 0 THEN
      v_nav := v_review_nav;
      v_menu_mode := 'review';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'root_manager_id', v_root,
    'published_at', v_row.published_at,
    'pages', public.validate_shop_pages(COALESCE(v_row.published_pages, '{}'::jsonb)),
    'navigation', v_nav,
    'menu_mode', v_menu_mode,
    'guest_chat_path', public.resolve_merchant_guest_chat_path(v_root),
    'custom_pages', public.validate_custom_pages(COALESCE(v_row.published_custom_pages, '[]'::jsonb)),
    'me_page', public.validate_me_page(COALESCE(v_row.published_me_page, '[]'::jsonb))
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_published_shop_config_for_root(
  p_root_manager_id uuid,
  p_review boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_row public.merchant_shop_configs%ROWTYPE;
  v_nav jsonb;
  v_review_nav jsonb;
  v_menu_mode text := 'standard';
BEGIN
  IF p_root_manager_id IS NULL
     OR NOT public.is_public_enterprise_content_root(p_root_manager_id) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_shop_configs
  WHERE root_manager_id = p_root_manager_id;

  IF NOT FOUND OR v_row.published_at IS NULL THEN
    RETURN NULL;
  END IF;

  v_nav := public.validate_shell_navigation(COALESCE(v_row.published_navigation, '[]'::jsonb));
  IF COALESCE(p_review, false) AND COALESCE(v_row.review_menu_enabled, false) THEN
    v_review_nav := public.validate_shell_navigation(COALESCE(v_row.published_review_navigation, '[]'::jsonb));
    IF jsonb_array_length(v_review_nav) > 0 THEN
      v_nav := v_review_nav;
      v_menu_mode := 'review';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'root_manager_id', p_root_manager_id,
    'published_at', v_row.published_at,
    'pages', public.validate_shop_pages(COALESCE(v_row.published_pages, '{}'::jsonb)),
    'navigation', v_nav,
    'menu_mode', v_menu_mode,
    'guest_chat_path', public.resolve_merchant_guest_chat_path(p_root_manager_id),
    'custom_pages', public.validate_custom_pages(COALESCE(v_row.published_custom_pages, '[]'::jsonb)),
    'me_page', public.validate_me_page(COALESCE(v_row.published_me_page, '[]'::jsonb))
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_published_shop_config(uuid, boolean)
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_published_shop_config_for_root(uuid, boolean)
  TO anon, authenticated, service_role;