-- Feature 133 第二部分：内容顶置 + 阅读量统计

CREATE OR REPLACE FUNCTION public.set_content_pinned(
  p_content_id uuid,
  p_pinned boolean,
  p_rank integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_eid uuid;
  v_item_eid uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', '未登录');
  END IF;

  v_eid := public.get_profile_enterprise_id(v_uid);

  SELECT e.id INTO v_item_eid
  FROM public.manager_content_items c
  JOIN public.profiles p ON p.id = c.root_manager_id
  JOIN public.enterprises e ON e.id = p.enterprise_id
  WHERE c.id = p_content_id;

  IF v_item_eid IS NULL OR v_item_eid <> v_eid THEN
    RETURN jsonb_build_object('error', '内容不存在或无权操作');
  END IF;

  IF NOT public.has_enterprise_permission('content', v_uid) THEN
    RETURN jsonb_build_object('error', '权限不足');
  END IF;

  UPDATE public.manager_content_items
     SET is_pinned = COALESCE(p_pinned, false),
         pinned_rank = COALESCE(p_rank, 0),
         updated_at = NOW()
   WHERE id = p_content_id;

  RETURN jsonb_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.set_content_pinned(uuid, boolean, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_content_pinned(uuid, boolean, integer) TO authenticated;

-- 公开内容详情：成功返回一次阅读量 +1（不去重，刷新累计），并返回最新 view_count
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
    jsonb_build_object(
      'id', id,
      'content_type', content_type,
      'title', title,
      'cover_url', cover_url,
      'article_doc', article_doc,
      'created_at', created_at,
      'updated_at', updated_at
    )
    INTO v_type, v_like_count, v_view_count, v_item
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

  v_view_count := COALESCE(v_view_count, 0) + 1;

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