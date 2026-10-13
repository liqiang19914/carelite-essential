-- ============================================================================
-- 达人口碑：客户侧公开读取（匿名安全，只返回 moderation_status='passed' 的帖子）
-- ============================================================================

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
SET search_path = ''
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

  SELECT COALESCE(jsonb_agg(to_jsonb(item) ORDER BY item.created_at DESC, item.id), '[]'::jsonb)
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
    ORDER BY p.created_at DESC, p.id
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

REVOKE ALL ON FUNCTION public.get_public_reputation_module(uuid, uuid, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_reputation_module(uuid, uuid, text, integer, integer) TO anon, authenticated;

-- 帖子详情 + 图片 + 评论
CREATE OR REPLACE FUNCTION public.get_public_reputation_post(
  p_manager_id uuid,
  p_post_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_post jsonb;
  v_images jsonb;
  v_comments jsonb;
BEGIN
  v_root := public.get_enterprise_root_manager_id(p_manager_id);
  IF v_root IS NULL OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object(
    'id', p.id,
    'root_manager_id', p.root_manager_id,
    'category_id', p.category_id,
    'title', p.title,
    'content', p.content,
    'like_count', p.like_count,
    'comment_count', p.comment_count,
    'created_at', p.created_at,
    'my_liked', EXISTS (
      SELECT 1 FROM public.reputation_likes l
      WHERE l.post_id = p.id AND l.user_id = auth.uid()
    ),
    'author_name', pr.nickname,
    'author_avatar_url', pr.avatar_url
  )
  INTO v_post
  FROM public.reputation_posts p
  LEFT JOIN public.profiles pr ON pr.id = p.author_user_id
  WHERE p.id = p_post_id
    AND p.root_manager_id = v_root
    AND p.moderation_status = 'passed';

  IF v_post IS NULL THEN
    RETURN NULL;
  END IF;

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

  RETURN v_post || jsonb_build_object('images', v_images, 'comments', v_comments);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_reputation_post(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_reputation_post(uuid, uuid) TO anon, authenticated;