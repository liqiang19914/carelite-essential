-- 公开列表：置顶优先 + 阅读量 + 封面版式 / 视频字段
CREATE OR REPLACE FUNCTION public.get_public_reputation_module(
  p_manager_id uuid,
  p_cat uuid DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_total integer;
  v_categories jsonb;
  v_posts jsonb;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  v_offset integer := LEAST(GREATEST(COALESCE(p_offset, 0), 0), 10000);
  v_search text := NULLIF(btrim(COALESCE(p_search, '')), '');
BEGIN
  v_root := public.get_enterprise_root_manager_id(p_manager_id);
  IF v_root IS NULL OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.sort_weight, c.name), '[]'::jsonb)
    INTO v_categories
  FROM (
    SELECT id, name, sort_weight
    FROM public.reputation_categories
    WHERE root_manager_id = v_root
  ) c;

  SELECT COUNT(*) INTO v_total
  FROM public.reputation_posts p
  WHERE p.root_manager_id = v_root
    AND p.moderation_status = 'passed'
    AND (p_cat IS NULL OR p.category_id = p_cat)
    AND (v_search IS NULL OR p.title ILIKE '%' || v_search || '%' OR p.content ILIKE '%' || v_search || '%');

  SELECT COALESCE(
    jsonb_agg(
      to_jsonb(item)
      ORDER BY item.is_pinned DESC, item.pinned_rank DESC, item.created_at DESC, item.id
    ),
    '[]'::jsonb
  )
    INTO v_posts
  FROM (
    SELECT
      p.id,
      p.category_id,
      p.title,
      p.content,
      p.like_count,
      p.comment_count,
      p.created_at,
      p.post_type,
      p.cover_layout,
      p.video_url,
      p.video_cover_url,
      p.video_duration_seconds,
      COALESCE(p.is_pinned, false) AS is_pinned,
      COALESCE(p.pinned_rank, 0) AS pinned_rank,
      COALESCE(p.view_count, 0) + COALESCE(p.base_view_count, 0) AS view_count,
      EXISTS (
        SELECT 1 FROM public.reputation_likes l
        WHERE l.post_id = p.id AND l.user_id = auth.uid()
      ) AS my_liked,
      pr.nickname AS author_name,
      pr.avatar_url AS author_avatar_url,
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('image_url', i.image_url, 'is_before', i.is_before) ORDER BY i.sort_order)
        FROM public.reputation_post_images i
        WHERE i.post_id = p.id
      ), '[]'::jsonb) AS images
    FROM public.reputation_posts p
    LEFT JOIN public.profiles pr ON pr.id = p.author_user_id
    WHERE p.root_manager_id = v_root
      AND p.moderation_status = 'passed'
      AND (p_cat IS NULL OR p.category_id = p_cat)
      AND (v_search IS NULL OR p.title ILIKE '%' || v_search || '%' OR p.content ILIKE '%' || v_search || '%')
    ORDER BY
      COALESCE(p.is_pinned, false) DESC,
      COALESCE(p.pinned_rank, 0) DESC,
      p.created_at DESC,
      p.id
    LIMIT v_limit OFFSET v_offset
  ) item;

  RETURN jsonb_build_object(
    'root_manager_id', v_root,
    'categories', v_categories,
    'total', v_total,
    'posts', v_posts
  );
END;
$function$;

-- 详情：原子累加真实阅读量；展示阅读量 = 真实 + 商户设定初始量
CREATE OR REPLACE FUNCTION public.get_public_reputation_post(
  p_manager_id uuid,
  p_post_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_post jsonb;
  v_images jsonb;
  v_comments jsonb;
  v_view_count integer;
  v_base_view integer;
BEGIN
  v_root := public.get_enterprise_root_manager_id(p_manager_id);
  IF v_root IS NULL OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN NULL;
  END IF;

  SELECT
    p.view_count,
    p.base_view_count,
    jsonb_build_object(
      'id', p.id,
      'root_manager_id', p.root_manager_id,
      'category_id', p.category_id,
      'title', p.title,
      'content', p.content,
      'like_count', p.like_count,
      'comment_count', p.comment_count,
      'created_at', p.created_at,
      'post_type', p.post_type,
      'cover_layout', p.cover_layout,
      'video_url', p.video_url,
      'video_cover_url', p.video_cover_url,
      'video_duration_seconds', p.video_duration_seconds,
      'is_pinned', COALESCE(p.is_pinned, false),
      'my_liked', EXISTS (
        SELECT 1 FROM public.reputation_likes l
        WHERE l.post_id = p.id AND l.user_id = auth.uid()
      ),
      'author_name', pr.nickname,
      'author_avatar_url', pr.avatar_url
    )
  INTO v_view_count, v_base_view, v_post
  FROM public.reputation_posts p
  LEFT JOIN public.profiles pr ON pr.id = p.author_user_id
  WHERE p.id = p_post_id
    AND p.root_manager_id = v_root
    AND p.moderation_status = 'passed';

  IF v_post IS NULL THEN
    RETURN NULL;
  END IF;

  UPDATE public.reputation_posts
     SET view_count = view_count + 1
   WHERE id = p_post_id;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object('id', id, 'image_url', image_url, 'is_before', is_before, 'sort_order', sort_order)
      ORDER BY sort_order
    ),
    '[]'::jsonb
  ) INTO v_images
  FROM public.reputation_post_images
  WHERE post_id = p_post_id;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object('id', c.id, 'content', c.content, 'nickname', COALESCE(pr2.nickname, '用户'), 'avatar_url', pr2.avatar_url, 'created_at', c.created_at)
      ORDER BY c.created_at DESC, c.id
    ),
    '[]'::jsonb
  ) INTO v_comments
  FROM public.reputation_comments c
  LEFT JOIN public.profiles pr2 ON pr2.id = c.user_id
  WHERE c.post_id = p_post_id;

  RETURN v_post || jsonb_build_object(
    'images', v_images,
    'comments', v_comments,
    'view_count', COALESCE(v_view_count, 0) + 1 + COALESCE(v_base_view, 0)
  );
END;
$function$;

-- 我的笔记：作者自己的全部笔记（含审核中），带品牌与分类以便跳转
CREATE OR REPLACE FUNCTION public.list_my_reputation_posts(
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_total integer;
  v_posts jsonb;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  v_offset integer := LEAST(GREATEST(COALESCE(p_offset, 0), 0), 10000);
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('total', 0, 'posts', '[]'::jsonb);
  END IF;

  SELECT COUNT(*) INTO v_total FROM public.reputation_posts WHERE author_user_id = v_uid;

  SELECT COALESCE(jsonb_agg(to_jsonb(item) ORDER BY item.created_at DESC, item.id), '[]'::jsonb)
    INTO v_posts
  FROM (
    SELECT
      p.id,
      p.root_manager_id,
      p.category_id,
      c.name AS category_name,
      p.title,
      p.content,
      p.like_count,
      p.comment_count,
      p.moderation_status,
      p.review_note,
      p.created_at,
      p.post_type,
      p.cover_layout,
      p.video_url,
      p.video_cover_url,
      p.video_duration_seconds,
      COALESCE(p.is_pinned, false) AS is_pinned,
      COALESCE(p.view_count, 0) + COALESCE(p.base_view_count, 0) AS view_count,
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('image_url', i.image_url, 'is_before', i.is_before) ORDER BY i.sort_order)
        FROM public.reputation_post_images i
        WHERE i.post_id = p.id
      ), '[]'::jsonb) AS images
    FROM public.reputation_posts p
    LEFT JOIN public.reputation_categories c ON c.id = p.category_id
    WHERE p.author_user_id = v_uid
    ORDER BY p.created_at DESC, p.id
    LIMIT v_limit OFFSET v_offset
  ) item;

  RETURN jsonb_build_object('total', v_total, 'posts', v_posts);
END;
$function$;

-- 商户后台：带阅读量、初始阅读量与置顶态，置顶优先
CREATE OR REPLACE FUNCTION public.list_enterprise_reputation_posts(
  p_root_manager_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_total integer;
  v_posts jsonb;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  v_offset integer := LEAST(GREATEST(COALESCE(p_offset, 0), 0), 10000);
BEGIN
  IF public.is_admin(auth.uid()) THEN
    v_root := p_root_manager_id;
  ELSE
    v_root := public.get_enterprise_root_manager_id(auth.uid());
  END IF;

  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限或未指定企业' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM public.reputation_posts
  WHERE root_manager_id = v_root;

  SELECT COALESCE(
    jsonb_agg(
      to_jsonb(item)
      ORDER BY item.is_pinned DESC, item.pinned_rank DESC, item.created_at DESC, item.id
    ),
    '[]'::jsonb
  )
    INTO v_posts
  FROM (
    SELECT
      p.id,
      p.category_id,
      c.name AS category_name,
      p.title,
      p.content,
      p.like_count,
      p.comment_count,
      p.moderation_status,
      p.review_note,
      p.created_at,
      p.post_type,
      p.cover_layout,
      p.video_url,
      p.video_cover_url,
      p.video_duration_seconds,
      COALESCE(p.is_pinned, false) AS is_pinned,
      COALESCE(p.pinned_rank, 0) AS pinned_rank,
      COALESCE(p.base_view_count, 0) AS base_view_count,
      COALESCE(p.view_count, 0) + COALESCE(p.base_view_count, 0) AS view_count,
      pr.nickname AS author_name,
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('image_url', i.image_url, 'is_before', i.is_before) ORDER BY i.sort_order)
        FROM public.reputation_post_images i
        WHERE i.post_id = p.id
      ), '[]'::jsonb) AS images
    FROM public.reputation_posts p
    LEFT JOIN public.reputation_categories c ON c.id = p.category_id
    LEFT JOIN public.profiles pr ON pr.id = p.author_user_id
    WHERE p.root_manager_id = v_root
    ORDER BY
      COALESCE(p.is_pinned, false) DESC,
      COALESCE(p.pinned_rank, 0) DESC,
      p.created_at DESC,
      p.id
    LIMIT v_limit OFFSET v_offset
  ) item;

  RETURN jsonb_build_object('total', v_total, 'posts', v_posts);
END;
$function$;