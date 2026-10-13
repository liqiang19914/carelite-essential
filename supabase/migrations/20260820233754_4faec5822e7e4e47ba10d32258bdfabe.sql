-- 底部菜单自定义 + 自定义页面：merchant_shop_configs 增加 4 个 jsonb 字段。
-- draft/published 双态与装修页面一致，随同一次「保存草稿 / 发布」原子生效。
ALTER TABLE public.merchant_shop_configs
  ADD COLUMN IF NOT EXISTS draft_navigation jsonb NOT NULL DEFAULT '[]',
  ADD COLUMN IF NOT EXISTS published_navigation jsonb NOT NULL DEFAULT '[]',
  ADD COLUMN IF NOT EXISTS draft_custom_pages jsonb NOT NULL DEFAULT '[]',
  ADD COLUMN IF NOT EXISTS published_custom_pages jsonb NOT NULL DEFAULT '[]';

COMMENT ON COLUMN public.merchant_shop_configs.draft_navigation IS
  '底部菜单草稿：[{id,label,icon,targetType,targetValue}]，3~5 项；空数组=未配置（客户端回落默认五项）';
COMMENT ON COLUMN public.merchant_shop_configs.published_navigation IS '底部菜单已发布版本';
COMMENT ON COLUMN public.merchant_shop_configs.draft_custom_pages IS
  '自定义页面草稿：[{id,title,modules}]，最多 5 个；空数组=没有自定义页面';
COMMENT ON COLUMN public.merchant_shop_configs.published_custom_pages IS '自定义页面已发布版本';

-- 底部菜单校验：空数组放行（未配置哨兵）；非空必须 3~5 项、编号唯一、
-- 文案 1~8 字、图标白名单、跳转类型白名单（内置页 / 自定义页面 / 链接）。
CREATE OR REPLACE FUNCTION public.validate_shell_navigation(p_nav jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_item jsonb;
  v_id text;
  v_label text;
  v_icon text;
  v_type text;
  v_value text;
  v_ids text[] := '{}';
  v_out jsonb := '[]'::jsonb;
BEGIN
  IF p_nav IS NULL OR jsonb_typeof(p_nav) <> 'array' THEN
    RAISE EXCEPTION '底部菜单数据格式不正确，请刷新后重试' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_nav) = 0 THEN
    RETURN '[]'::jsonb;
  END IF;
  IF jsonb_array_length(p_nav) < 3 OR jsonb_array_length(p_nav) > 5 THEN
    RAISE EXCEPTION '底部菜单需要 3~5 个，请调整后重试' USING ERRCODE = '22023';
  END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_nav)
  LOOP
    IF jsonb_typeof(v_item) <> 'object' THEN
      RAISE EXCEPTION '存在无效的菜单项，请刷新后重试' USING ERRCODE = '22023';
    END IF;
    v_id := NULLIF(btrim(v_item->>'id'), '');
    IF v_id IS NULL OR char_length(v_id) > 40 THEN
      RAISE EXCEPTION '存在缺少编号的菜单项，请刷新后重试' USING ERRCODE = '22023';
    END IF;
    IF v_id = ANY(v_ids) THEN
      RAISE EXCEPTION '菜单项编号重复，请刷新后重试' USING ERRCODE = '22023';
    END IF;
    v_ids := v_ids || v_id;
    v_label := NULLIF(btrim(v_item->>'label'), '');
    IF v_label IS NULL OR char_length(v_label) > 8 THEN
      RAISE EXCEPTION '菜单名称需要 1~8 个字，请检查后重试' USING ERRCODE = '22023';
    END IF;
    v_icon := v_item->>'icon';
    IF v_icon IS NULL OR v_icon <> ALL(ARRAY['home','message','heart','handshake','scale','store','book','article','course','image','star','user','folder','headset','link','compass']) THEN
      RAISE EXCEPTION '存在不支持的菜单图标，请刷新后重试' USING ERRCODE = '22023';
    END IF;
    v_type := v_item->>'targetType';
    v_value := v_item->>'targetValue';
    IF v_type = 'builtin' THEN
      IF v_value IS NULL OR v_value <> ALL(ARRAY['home','chat','manager','weighing','shop','content','me']) THEN
        RAISE EXCEPTION '存在不支持的菜单跳转页面，请刷新后重试' USING ERRCODE = '22023';
      END IF;
    ELSIF v_type = 'custom_page' THEN
      IF v_value IS NULL OR v_value !~ '^[a-z0-9][a-z0-9_-]{0,39}$' THEN
        RAISE EXCEPTION '菜单指向的自定义页面不正确，请刷新后重试' USING ERRCODE = '22023';
      END IF;
    ELSIF v_type = 'custom' THEN
      IF v_value IS NULL OR char_length(v_value) > 500
         OR (v_value !~ '^https://' AND v_value !~ '^/') THEN
        RAISE EXCEPTION '自定义链接需要以 https:// 或 / 开头，请检查后重试' USING ERRCODE = '22023';
      END IF;
    ELSE
      RAISE EXCEPTION '存在不支持的菜单跳转类型，请刷新后重试' USING ERRCODE = '22023';
    END IF;
    v_out := v_out || jsonb_build_object('id', v_id, 'label', v_label, 'icon', v_icon, 'targetType', v_type, 'targetValue', v_value);
  END LOOP;
  RETURN v_out;
END;
$function$;

-- 自定义页面校验：空数组放行；非空最多 5 个、编号唯一且符合规则、
-- 标题 1~10 字、模块列表走模块归一化。
CREATE OR REPLACE FUNCTION public.validate_custom_pages(p_pages jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_page jsonb;
  v_id text;
  v_title text;
  v_ids text[] := '{}';
  v_out jsonb := '[]'::jsonb;
BEGIN
  IF p_pages IS NULL OR jsonb_typeof(p_pages) <> 'array' THEN
    RAISE EXCEPTION '自定义页面数据格式不正确，请刷新后重试' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_pages) = 0 THEN
    RETURN '[]'::jsonb;
  END IF;
  IF jsonb_array_length(p_pages) > 5 THEN
    RAISE EXCEPTION '自定义页面最多 5 个，请删减后重试' USING ERRCODE = '22023';
  END IF;
  FOR v_page IN SELECT value FROM jsonb_array_elements(p_pages)
  LOOP
    IF jsonb_typeof(v_page) <> 'object' THEN
      RAISE EXCEPTION '存在无效的自定义页面，请刷新后重试' USING ERRCODE = '22023';
    END IF;
    v_id := NULLIF(btrim(v_page->>'id'), '');
    IF v_id IS NULL OR v_id !~ '^[a-z0-9][a-z0-9_-]{0,39}$' THEN
      RAISE EXCEPTION '自定义页面编号不正确，请刷新后重试' USING ERRCODE = '22023';
    END IF;
    IF v_id = ANY(v_ids) THEN
      RAISE EXCEPTION '自定义页面编号重复，请刷新后重试' USING ERRCODE = '22023';
    END IF;
    v_ids := v_ids || v_id;
    v_title := NULLIF(btrim(v_page->>'title'), '');
    IF v_title IS NULL OR char_length(v_title) > 10 THEN
      RAISE EXCEPTION '自定义页面标题需要 1~10 个字，请检查后重试' USING ERRCODE = '22023';
    END IF;
    v_out := v_out || jsonb_build_object(
      'id', v_id,
      'title', v_title,
      'modules', public.normalize_shop_module_list(COALESCE(v_page->'modules', '[]'::jsonb))
    );
  END LOOP;
  RETURN v_out;
END;
$function$;

-- 商户读自己企业的装修配置：补 navigation / custom_pages 两份配置
CREATE OR REPLACE FUNCTION public.get_my_shop_config(p_root_manager_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
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

  RETURN jsonb_build_object(
    'root_manager_id', v_root,
    'draft_pages', v_draft,
    'published_pages', v_published,
    'draft_navigation', v_draft_nav,
    'published_navigation', v_published_nav,
    'draft_custom_pages', v_draft_custom,
    'published_custom_pages', v_published_custom,
    'published_at', v_row.published_at,
    'has_draft', (v_row.root_manager_id IS NOT NULL) AND (
        v_draft IS DISTINCT FROM v_published
        OR v_draft_nav IS DISTINCT FROM v_published_nav
        OR v_draft_custom IS DISTINCT FROM v_published_custom
      )
  );
END;
$function$;

-- 商户保存草稿：新增 p_navigation / p_custom_pages 两个可选参数。
-- 传 NULL 保留现有值（兼容旧调用与局部保存）；非 NULL 先校验再落库。
DROP FUNCTION IF EXISTS public.save_shop_config_draft(jsonb, uuid);

CREATE OR REPLACE FUNCTION public.save_shop_config_draft(
  p_pages jsonb,
  p_root_manager_id uuid DEFAULT NULL,
  p_navigation jsonb DEFAULT NULL,
  p_custom_pages jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_row public.merchant_shop_configs%ROWTYPE;
  v_normalized jsonb;
  v_nav jsonb;
  v_custom jsonb;
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

  INSERT INTO public.merchant_shop_configs
    (root_manager_id, draft_pages, draft_navigation, draft_custom_pages, created_by, updated_by)
  VALUES (v_root, v_normalized, v_nav, v_custom, v_uid, v_uid)
  ON CONFLICT (root_manager_id) DO UPDATE
    SET draft_pages = EXCLUDED.draft_pages,
        draft_navigation = EXCLUDED.draft_navigation,
        draft_custom_pages = EXCLUDED.draft_custom_pages,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object(
    'success', true,
    'root_manager_id', v_root,
    'draft_pages', v_normalized,
    'draft_navigation', v_nav,
    'draft_custom_pages', v_custom
  );
END;
$function$;

-- 商户发布：草稿整体（页面 + 菜单 + 自定义页面）拷贝到已发布
CREATE OR REPLACE FUNCTION public.publish_shop_config(p_root_manager_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_draft jsonb;
  v_nav jsonb;
  v_custom jsonb;
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

  SELECT draft_pages, draft_navigation, draft_custom_pages
    INTO v_draft, v_nav, v_custom
    FROM public.merchant_shop_configs
    WHERE root_manager_id = v_root;

  v_draft := public.validate_shop_pages(COALESCE(v_draft, '{}'::jsonb));
  v_nav := public.validate_shell_navigation(COALESCE(v_nav, '[]'::jsonb));
  v_custom := public.validate_custom_pages(COALESCE(v_custom, '[]'::jsonb));

  INSERT INTO public.merchant_shop_configs
    (root_manager_id, draft_pages, published_pages,
     draft_navigation, published_navigation,
     draft_custom_pages, published_custom_pages,
     published_at, created_by, updated_by)
  VALUES (v_root, v_draft, v_draft, v_nav, v_nav, v_custom, v_custom, now(), v_uid, v_uid)
  ON CONFLICT (root_manager_id) DO UPDATE
    SET published_pages = EXCLUDED.published_pages,
        published_navigation = EXCLUDED.published_navigation,
        published_custom_pages = EXCLUDED.published_custom_pages,
        published_at = EXCLUDED.published_at,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object('success', true, 'root_manager_id', v_root, 'published_at', now());
END;
$function$;

-- 公开读取（按健管师入口）：补 navigation / custom_pages
CREATE OR REPLACE FUNCTION public.get_published_shop_config(p_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_row public.merchant_shop_configs%ROWTYPE;
BEGIN
  v_root := public.get_enterprise_root_manager_id(p_manager_id);
  IF v_root IS NULL OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row FROM public.merchant_shop_configs WHERE root_manager_id = v_root;

  RETURN jsonb_build_object(
    'root_manager_id', v_root,
    'published_at', v_row.published_at,
    'pages', public.validate_shop_pages(COALESCE(v_row.published_pages, '{}'::jsonb)),
    'navigation', public.validate_shell_navigation(COALESCE(v_row.published_navigation, '[]'::jsonb)),
    'custom_pages', public.validate_custom_pages(COALESCE(v_row.published_custom_pages, '[]'::jsonb))
  );
END;
$function$;

-- 公开读取（按企业根直读）：补 navigation / custom_pages
CREATE OR REPLACE FUNCTION public.get_published_shop_config_for_root(p_root_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row public.merchant_shop_configs%ROWTYPE;
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

  RETURN jsonb_build_object(
    'root_manager_id', p_root_manager_id,
    'published_at', v_row.published_at,
    'pages', public.validate_shop_pages(COALESCE(v_row.published_pages, '{}'::jsonb)),
    'navigation', public.validate_shell_navigation(COALESCE(v_row.published_navigation, '[]'::jsonb)),
    'custom_pages', public.validate_custom_pages(COALESCE(v_row.published_custom_pages, '[]'::jsonb))
  );
END;
$function$;

-- 权限：校验函数不对外开放；读写 RPC 与既有装修函数保持同一授权面
REVOKE ALL ON FUNCTION public.validate_shell_navigation(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.validate_custom_pages(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_shop_config(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_shop_config(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.save_shop_config_draft(jsonb, uuid, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_shop_config_draft(jsonb, uuid, jsonb, jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.publish_shop_config(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.publish_shop_config(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_published_shop_config(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_published_shop_config(uuid) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.get_published_shop_config_for_root(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_published_shop_config_for_root(uuid) TO anon, authenticated;