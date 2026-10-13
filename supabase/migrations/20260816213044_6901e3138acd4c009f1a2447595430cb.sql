-- 商户店铺装修系统：配置表 + 读取/保存/发布接口
-- 归属列 root_manager_id（企业根商户），与内容中心口径一致。
-- 客户只能走 get_published_shop_config 读已发布配置；商户经 SECURITY DEFINER RPC 读写草稿/发布。

CREATE TABLE IF NOT EXISTS public.merchant_shop_configs (
  root_manager_id uuid PRIMARY KEY
    REFERENCES public.managers(id) ON DELETE CASCADE,
  draft_pages jsonb NOT NULL DEFAULT '{"home":[],"school":[]}'::jsonb,
  published_pages jsonb NOT NULL DEFAULT '{"home":[],"school":[]}'::jsonb,
  published_at timestamptz,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.merchant_shop_configs IS
  '商户店铺装修配置：按企业根商户一份，草稿/已发布两套页面（home 首页 / school 学堂）';
COMMENT ON COLUMN public.merchant_shop_configs.draft_pages IS
  '草稿页面 {home:[{type,data}], school:[...]}，数组顺序即渲染顺序';
COMMENT ON COLUMN public.merchant_shop_configs.published_pages IS
  '已发布页面，发布时由草稿整体拷贝';

-- 校验并规范化单个模块数组：每项必须 {type, data}，type 非空且 <=50 字符
CREATE OR REPLACE FUNCTION public.normalize_shop_module_list(p_list jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_mod jsonb;
  v_type text;
  v_data jsonb;
  v_out jsonb := '[]'::jsonb;
BEGIN
  IF p_list IS NULL OR jsonb_typeof(p_list) <> 'array' THEN
    RAISE EXCEPTION '模块数据格式不正确，请刷新后重试' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_list) > 60 THEN
    RAISE EXCEPTION '单页模块最多 60 个，请精简后重试' USING ERRCODE = '22023';
  END IF;
  FOR v_mod IN SELECT value FROM jsonb_array_elements(p_list)
  LOOP
    IF jsonb_typeof(v_mod) <> 'object' THEN
      RAISE EXCEPTION '存在无效的模块，请刷新后重试' USING ERRCODE = '22023';
    END IF;
    v_type := NULLIF(btrim(v_mod->>'type'), '');
    IF v_type IS NULL OR char_length(v_type) > 50 THEN
      RAISE EXCEPTION '存在缺少类型的模块，请刷新后重试' USING ERRCODE = '22023';
    END IF;
    v_data := v_mod->'data';
    IF v_data IS NULL OR jsonb_typeof(v_data) <> 'object' THEN
      v_data := '{}'::jsonb;
    END IF;
    v_out := v_out || jsonb_build_object('type', v_type, 'data', v_data);
  END LOOP;
  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION public.validate_shop_pages(p_pages jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
BEGIN
  IF p_pages IS NULL OR jsonb_typeof(p_pages) <> 'object' THEN
    RAISE EXCEPTION '装修数据结构不正确，请刷新后重试' USING ERRCODE = '22023';
  END IF;
  RETURN jsonb_build_object(
    'home', public.normalize_shop_module_list(COALESCE(p_pages->'home', '[]'::jsonb)),
    'school', public.normalize_shop_module_list(COALESCE(p_pages->'school', '[]'::jsonb))
  );
END;
$$;

-- 商户读自己企业的装修配置（含草稿+已发布）；管理员可指定企业
CREATE OR REPLACE FUNCTION public.get_my_shop_config(p_root_manager_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_row public.merchant_shop_configs%ROWTYPE;
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

  RETURN jsonb_build_object(
    'root_manager_id', v_root,
    'draft_pages', COALESCE(v_row.draft_pages, '{"home":[],"school":[]}'::jsonb),
    'published_pages', COALESCE(v_row.published_pages, '{"home":[],"school":[]}'::jsonb),
    'published_at', v_row.published_at,
    'has_draft', (v_row IS NOT NULL) AND (v_row.draft_pages IS DISTINCT FROM v_row.published_pages)
  );
END;
$$;

-- 商户保存草稿（只写 draft_pages，不动 published）；管理员可指定企业
CREATE OR REPLACE FUNCTION public.save_shop_config_draft(p_pages jsonb, p_root_manager_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_normalized jsonb;
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

  v_normalized := public.validate_shop_pages(p_pages);

  INSERT INTO public.merchant_shop_configs (root_manager_id, draft_pages, created_by, updated_by)
  VALUES (v_root, v_normalized, v_uid, v_uid)
  ON CONFLICT (root_manager_id) DO UPDATE
    SET draft_pages = EXCLUDED.draft_pages,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object('success', true, 'root_manager_id', v_root, 'draft_pages', v_normalized);
END;
$$;

-- 商户发布：草稿整体拷贝到已发布；管理员可指定企业
CREATE OR REPLACE FUNCTION public.publish_shop_config(p_root_manager_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
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
  v_draft := COALESCE(v_draft, '{"home":[],"school":[]}'::jsonb);

  INSERT INTO public.merchant_shop_configs (root_manager_id, draft_pages, published_pages, published_at, created_by, updated_by)
  VALUES (v_root, v_draft, v_draft, now(), v_uid, v_uid)
  ON CONFLICT (root_manager_id) DO UPDATE
    SET published_pages = EXCLUDED.published_pages,
        published_at = EXCLUDED.published_at,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object('success', true, 'root_manager_id', v_root, 'published_at', now());
END;
$$;

-- 客户侧公开读取：入口管理师 ID（可能是员工）→ 企业根 → 只返回已发布配置
CREATE OR REPLACE FUNCTION public.get_published_shop_config(p_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $$
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
    'pages', COALESCE(v_row.published_pages, '{"home":[],"school":[]}'::jsonb)
  );
END;
$$;

-- 授权：公开读取给 anon+authenticated；管理类只给 authenticated；收紧防 DROP+CREATE 重授
REVOKE ALL ON FUNCTION public.normalize_shop_module_list(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.validate_shop_pages(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_shop_config(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_shop_config(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.save_shop_config_draft(jsonb, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_shop_config_draft(jsonb, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.publish_shop_config(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.publish_shop_config(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_published_shop_config(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_published_shop_config(uuid) TO anon, authenticated;

-- 表级权限：匿名与前端一律不直接碰表，全部经 RPC
ALTER TABLE public.merchant_shop_configs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.merchant_shop_configs FROM anon, authenticated;