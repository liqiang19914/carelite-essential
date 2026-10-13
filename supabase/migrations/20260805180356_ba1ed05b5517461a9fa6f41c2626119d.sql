-- 商户内容中心：客户侧公开读取（匿名安全）
--
-- 客户手上只有一个「入口管理师 ID」，可能是员工的。这两个函数把它映射成唯一企业根，
-- 再只返回 is_published AND moderation_status='passed' 的内容。
-- anon 对三张基础表没有任何表级权限，只能走这两个入口，无法横扫别家企业。

CREATE OR REPLACE FUNCTION public.get_public_content_module(
  p_manager_id uuid,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_root uuid;
  v_name text;
  v_total integer;
  v_items jsonb;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  v_offset integer := LEAST(GREATEST(COALESCE(p_offset, 0), 0), 10000);
BEGIN
  v_root := public.get_enterprise_root_manager_id(p_manager_id);

  IF v_root IS NULL
     OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN NULL;
  END IF;

  SELECT NULLIF(btrim(display_name), '') INTO v_name
  FROM public.manager_content_spaces
  WHERE root_manager_id = v_root;

  SELECT COUNT(*) INTO v_total
  FROM public.manager_content_items
  WHERE root_manager_id = v_root
    AND is_published = true
    AND moderation_status = 'passed';

  SELECT COALESCE(jsonb_agg(to_jsonb(item)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT
      i.id,
      i.content_type,
      i.title,
      i.cover_url,
      i.sort_weight,
      i.created_at,
      i.updated_at,
      CASE
        WHEN i.content_type = 'album' THEN (
          SELECT COUNT(*)
          FROM public.manager_content_album_pages p
          WHERE p.content_id = i.id
        )
        ELSE 0
      END AS page_count
    FROM public.manager_content_items i
    WHERE i.root_manager_id = v_root
      AND i.is_published = true
      AND i.moderation_status = 'passed'
    ORDER BY i.sort_weight DESC, i.created_at DESC, i.id
    LIMIT v_limit OFFSET v_offset
  ) item;

  RETURN jsonb_build_object(
    'root_manager_id', v_root,
    'display_name', COALESCE(v_name, '健康学堂'),
    'total', v_total,
    'items', v_items
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_public_content_module(uuid, integer, integer)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_content_module(uuid, integer, integer)
  TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_public_content_item(
  p_manager_id uuid,
  p_content_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_root uuid;
  v_name text;
  v_item jsonb;
  v_pages jsonb := '[]'::jsonb;
  v_type text;
BEGIN
  v_root := public.get_enterprise_root_manager_id(p_manager_id);

  IF v_root IS NULL
     OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN NULL;
  END IF;

  SELECT NULLIF(btrim(display_name), '') INTO v_name
  FROM public.manager_content_spaces
  WHERE root_manager_id = v_root;

  SELECT
    content_type,
    jsonb_build_object(
      'id', id,
      'content_type', content_type,
      'title', title,
      'cover_url', cover_url,
      'article_doc', article_doc,
      'created_at', created_at,
      'updated_at', updated_at
    )
    INTO v_type, v_item
  FROM public.manager_content_items
  WHERE id = p_content_id
    AND root_manager_id = v_root
    AND is_published = true
    AND moderation_status = 'passed';

  IF v_item IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_type = 'album' THEN
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id', id,
          'sort_order', sort_order,
          'image_url', image_url,
          'alt_text', alt_text
        ) ORDER BY sort_order
      ),
      '[]'::jsonb
    ) INTO v_pages
    FROM public.manager_content_album_pages
    WHERE content_id = p_content_id;
  END IF;

  RETURN v_item || jsonb_build_object(
    'root_manager_id', v_root,
    'display_name', COALESCE(v_name, '健康学堂'),
    'pages', v_pages
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_public_content_item(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_content_item(uuid, uuid)
  TO anon, authenticated;