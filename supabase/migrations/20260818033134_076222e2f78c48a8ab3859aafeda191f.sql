-- 店铺装修作用域扩展：在原有 home（健康管理师页）/ school（学堂页，保留兼容）之外
-- 新增 content（内容中心）与 shop（商城）两页。存量数据不动，缺失的页键读出来一律补空数组。

ALTER TABLE public.merchant_shop_configs
  ALTER COLUMN draft_pages SET DEFAULT '{"home":[],"school":[],"content":[],"shop":[]}'::jsonb,
  ALTER COLUMN published_pages SET DEFAULT '{"home":[],"school":[],"content":[],"shop":[]}'::jsonb;

COMMENT ON COLUMN public.merchant_shop_configs.draft_pages IS
  '草稿页面 {home:[{type,data}], school:[...], content:[...], shop:[...]}，数组顺序即渲染顺序；home=健康管理师页 school=学堂页(兼容) content=内容中心 shop=商城';

CREATE OR REPLACE FUNCTION public.validate_shop_pages(p_pages jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
BEGIN
  IF p_pages IS NULL OR jsonb_typeof(p_pages) <> 'object' THEN
    RAISE EXCEPTION '装修数据结构不正确，请刷新后重试' USING ERRCODE = '22023';
  END IF;
  RETURN jsonb_build_object(
    'home', public.normalize_shop_module_list(COALESCE(p_pages->'home', '[]'::jsonb)),
    'school', public.normalize_shop_module_list(COALESCE(p_pages->'school', '[]'::jsonb)),
    'content', public.normalize_shop_module_list(COALESCE(p_pages->'content', '[]'::jsonb)),
    'shop', public.normalize_shop_module_list(COALESCE(p_pages->'shop', '[]'::jsonb))
  );
END;
$function$;

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

  -- 读出来先补齐四个页键，老配置缺 content/shop 时前端不用再猜
  v_draft := public.validate_shop_pages(COALESCE(v_row.draft_pages, '{}'::jsonb));
  v_published := public.validate_shop_pages(COALESCE(v_row.published_pages, '{}'::jsonb));

  RETURN jsonb_build_object(
    'root_manager_id', v_root,
    'draft_pages', v_draft,
    'published_pages', v_published,
    'published_at', v_row.published_at,
    'has_draft', (v_row.root_manager_id IS NOT NULL) AND (v_draft IS DISTINCT FROM v_published)
  );
END;
$function$;

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

  SELECT draft_pages INTO v_draft FROM public.merchant_shop_configs WHERE root_manager_id = v_root;
  v_draft := public.validate_shop_pages(COALESCE(v_draft, '{}'::jsonb));

  INSERT INTO public.merchant_shop_configs (root_manager_id, draft_pages, published_pages, published_at, created_by, updated_by)
  VALUES (v_root, v_draft, v_draft, now(), v_uid, v_uid)
  ON CONFLICT (root_manager_id) DO UPDATE
    SET published_pages = EXCLUDED.published_pages,
        published_at = EXCLUDED.published_at,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object('success', true, 'root_manager_id', v_root, 'published_at', now());
END;
$function$;

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
    'pages', public.validate_shop_pages(COALESCE(v_row.published_pages, '{}'::jsonb))
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.validate_shop_pages(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_shop_config(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_shop_config(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.publish_shop_config(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.publish_shop_config(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_published_shop_config(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_published_shop_config(uuid) TO anon, authenticated;