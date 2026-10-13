-- 商户内容中心：正文骨架校验 + 板块名称读写 + 画册页原子替换

-- 1. 正文是否有实质内容（文字 / 图片 / 视频任一即算）
CREATE OR REPLACE FUNCTION public.manager_content_document_has_body(
  p_document jsonb
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_node jsonb;
BEGIN
  IF p_document IS NULL
     OR jsonb_typeof(p_document) <> 'object'
     OR p_document->>'type' <> 'doc'
     OR jsonb_typeof(p_document->'content') <> 'array' THEN
    RETURN false;
  END IF;

  FOR v_node IN SELECT value FROM jsonb_array_elements(p_document->'content')
  LOOP
    IF v_node->>'type' IN ('image', 'contentVideo') THEN
      RETURN true;
    END IF;
    IF btrim(COALESCE(v_node->>'text', '')) <> '' THEN
      RETURN true;
    END IF;
    IF jsonb_typeof(v_node->'content') = 'array'
       AND jsonb_array_length(v_node->'content') > 0 THEN
      RETURN true;
    END IF;
  END LOOP;

  RETURN false;
END;
$$;

-- 2. 商户读自己企业的板块设置（只认 auth.uid()，不接受外部企业 ID）
CREATE OR REPLACE FUNCTION public.get_my_content_space()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_name text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再管理内容' USING ERRCODE = '28000';
  END IF;

  IF NOT public.is_active_enterprise_content_member(v_uid) THEN
    RAISE EXCEPTION '所属企业当前不可使用内容管理，请联系企业负责人或平台处理'
      USING ERRCODE = '42501';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);

  SELECT NULLIF(btrim(display_name), '') INTO v_name
  FROM public.manager_content_spaces
  WHERE root_manager_id = v_root;

  RETURN jsonb_build_object(
    'root_manager_id', v_root,
    'display_name', COALESCE(v_name, '健康学堂'),
    'is_custom_name', v_name IS NOT NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_content_space() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_content_space() TO authenticated;

-- 3. 保存板块名称：普通商户忽略入参企业 ID，只能改自己企业；管理员可指定企业
CREATE OR REPLACE FUNCTION public.save_content_space_name(
  p_display_name text,
  p_root_manager_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_name text := NULLIF(btrim(p_display_name), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再保存' USING ERRCODE = '28000';
  END IF;

  IF char_length(COALESCE(v_name, '')) > 30 THEN
    RAISE EXCEPTION '客户端显示名称最多 30 个字，请精简后重试' USING ERRCODE = '22023';
  END IF;

  IF public.is_admin(v_uid) THEN
    v_root := p_root_manager_id;
    IF v_root IS NULL
       OR NOT EXISTS (SELECT 1 FROM public.managers WHERE id = v_root) THEN
      RAISE EXCEPTION '请选择有效企业' USING ERRCODE = '22023';
    END IF;
  ELSE
    IF NOT public.is_active_enterprise_content_member(v_uid) THEN
      RAISE EXCEPTION '所属企业当前不可修改板块名称，请联系企业负责人或平台处理'
        USING ERRCODE = '42501';
    END IF;
    v_root := public.get_enterprise_root_manager_id(v_uid);
  END IF;

  INSERT INTO public.manager_content_spaces (
    root_manager_id, display_name, created_by, updated_by
  )
  VALUES (v_root, v_name, v_uid, v_uid)
  ON CONFLICT (root_manager_id) DO UPDATE
    SET display_name = EXCLUDED.display_name,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object(
    'root_manager_id', v_root,
    'display_name', COALESCE(v_name, '健康学堂'),
    'is_custom_name', v_name IS NOT NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION public.save_content_space_name(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_content_space_name(text, uuid) TO authenticated;

-- 4. 画册页原子替换：一次事务内删旧插新，顺序按数组下标重排
--    与现状完全一致时直接返回、不写库，避免无意义地把已上线画册打回重检
CREATE OR REPLACE FUNCTION public.replace_content_album_pages(
  p_content_id uuid,
  p_pages jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_item public.manager_content_items%ROWTYPE;
  v_pages jsonb := COALESCE(p_pages, '[]'::jsonb);
  v_count integer;
  v_existing jsonb;
  v_normalized jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再保存画册' USING ERRCODE = '28000';
  END IF;

  IF jsonb_typeof(v_pages) <> 'array' THEN
    RAISE EXCEPTION '画册图片数据格式不正确，请刷新后重试' USING ERRCODE = '22023';
  END IF;

  v_count := jsonb_array_length(v_pages);
  IF v_count > 100 THEN
    RAISE EXCEPTION '单个画册最多 100 页，请删除部分图片后重试' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_item
  FROM public.manager_content_items
  WHERE id = p_content_id
  FOR UPDATE;

  IF NOT FOUND OR v_item.content_type <> 'album' THEN
    RAISE EXCEPTION '画册不存在，请返回列表后重试' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.is_admin(v_uid)
     AND (
       NOT public.is_active_enterprise_content_member(v_uid)
       OR v_item.root_manager_id IS DISTINCT FROM
          public.get_enterprise_root_manager_id(v_uid)
     ) THEN
    RAISE EXCEPTION '你无权修改该画册' USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_pages) AS e(page)
    WHERE jsonb_typeof(page) <> 'object'
       OR NULLIF(btrim(page->>'image_url'), '') IS NULL
       OR NULLIF(btrim(page->>'image_storage_key'), '') IS NULL
  ) THEN
    RAISE EXCEPTION '有图片还没上传完成，请重试上传或删除失败的那几张'
      USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'image_url', image_url,
        'image_storage_key', image_storage_key,
        'alt_text', alt_text
      ) ORDER BY sort_order
    ),
    '[]'::jsonb
  ) INTO v_existing
  FROM public.manager_content_album_pages
  WHERE content_id = p_content_id;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'image_url', page->>'image_url',
        'image_storage_key', page->>'image_storage_key',
        'alt_text', NULLIF(btrim(page->>'alt_text'), '')
      ) ORDER BY ord
    ),
    '[]'::jsonb
  ) INTO v_normalized
  FROM jsonb_array_elements(v_pages) WITH ORDINALITY AS e(page, ord);

  IF v_existing = v_normalized THEN
    RETURN jsonb_build_object(
      'success', true,
      'content_id', p_content_id,
      'page_count', v_count,
      'changed', false
    );
  END IF;

  DELETE FROM public.manager_content_album_pages WHERE content_id = p_content_id;

  INSERT INTO public.manager_content_album_pages (
    content_id, root_manager_id, sort_order,
    image_url, image_storage_key, alt_text, created_by, updated_by
  )
  SELECT
    p_content_id,
    v_item.root_manager_id,
    (ord - 1)::integer,
    page->>'image_url',
    page->>'image_storage_key',
    NULLIF(btrim(page->>'alt_text'), ''),
    v_uid,
    v_uid
  FROM jsonb_array_elements(v_pages) WITH ORDINALITY AS e(page, ord);

  RETURN jsonb_build_object(
    'success', true,
    'content_id', p_content_id,
    'page_count', v_count,
    'changed', true
  );
END;
$$;

REVOKE ALL ON FUNCTION public.replace_content_album_pages(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.replace_content_album_pages(uuid, jsonb) TO authenticated;