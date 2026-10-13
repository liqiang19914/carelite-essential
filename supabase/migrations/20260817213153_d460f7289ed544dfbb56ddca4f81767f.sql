-- 内容支持「初始阅读量」：商户后台可设置一个基数，用户端展示 = 基数 + 真实浏览
ALTER TABLE public.manager_content_items
  ADD COLUMN IF NOT EXISTS base_view_count integer NOT NULL DEFAULT 0;

ALTER TABLE public.manager_content_items
  DROP CONSTRAINT IF EXISTS manager_content_items_base_view_count_check;

ALTER TABLE public.manager_content_items
  ADD CONSTRAINT manager_content_items_base_view_count_check
  CHECK (base_view_count >= 0 AND base_view_count <= 100000000);

-- 该表的读写权限是按列授予的，新列必须显式补授，否则商户端读不到也写不了
GRANT SELECT (base_view_count) ON public.manager_content_items TO anon, authenticated, service_role;
GRANT UPDATE (base_view_count) ON public.manager_content_items TO authenticated, service_role;

-- 用户端详情：阅读量返回「初始阅读量 + 真实浏览次数」
CREATE OR REPLACE FUNCTION public.get_public_content_item(p_manager_id uuid, p_content_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_name text;
  v_item jsonb;
  v_pages jsonb := '[]'::jsonb;
  v_type text;
  v_like_count integer;
  v_view_count integer;
  v_base_view integer;
  v_my_liked boolean := false;
  v_uid uuid := auth.uid();
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
    like_count,
    view_count,
    base_view_count,
    jsonb_build_object(
      'id', id,
      'content_type', content_type,
      'title', title,
      'cover_url', cover_url,
      'article_doc', article_doc,
      'created_at', created_at,
      'updated_at', updated_at
    )
    INTO v_type, v_like_count, v_view_count, v_base_view, v_item
  FROM public.manager_content_items
  WHERE id = p_content_id
    AND root_manager_id = v_root
    AND is_published = true
    AND moderation_status = 'passed';

  IF v_item IS NULL THEN
    RETURN NULL;
  END IF;

  UPDATE public.manager_content_items
     SET view_count = view_count + 1
   WHERE id = p_content_id;

  v_view_count := COALESCE(v_view_count, 0) + 1 + COALESCE(v_base_view, 0);

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

  IF v_uid IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.manager_content_likes
      WHERE content_id = p_content_id AND user_id = v_uid
    ) INTO v_my_liked;
  END IF;

  RETURN v_item || jsonb_build_object(
    'root_manager_id', v_root,
    'display_name', COALESCE(v_name, '健康学堂'),
    'pages', v_pages,
    'like_count', COALESCE(v_like_count, 0),
    'view_count', COALESCE(v_view_count, 0),
    'my_liked', COALESCE(v_my_liked, false)
  );
END;
$function$;

-- 用户端列表：补出阅读量/点赞量，供卡片式列表展示
CREATE OR REPLACE FUNCTION public.get_public_content_module(p_manager_id uuid, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      i.like_count,
      COALESCE(i.view_count, 0) + COALESCE(i.base_view_count, 0) AS view_count,
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
$function$;