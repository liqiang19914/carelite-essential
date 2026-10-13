-- ============================================================================
-- 达人口碑：用户发帖 / 点赞 / 评论（authenticated，全走 RPC）
-- ============================================================================

CREATE OR REPLACE FUNCTION public.create_reputation_post(
  p_category_id uuid,
  p_title text,
  p_content text,
  p_images jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_post_id uuid;
  v_img jsonb;
  v_idx integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '请先登录后再发布' USING ERRCODE = '42501';
  END IF;

  SELECT root_manager_id INTO v_root
  FROM public.reputation_categories
  WHERE id = p_category_id;

  IF v_root IS NULL THEN
    RAISE EXCEPTION '所选分类不存在' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.reputation_posts
    (root_manager_id, category_id, author_user_id, title, content)
  VALUES
    (v_root, p_category_id, auth.uid(), btrim(p_title), btrim(p_content))
  RETURNING id INTO v_post_id;

  FOR v_img IN SELECT * FROM jsonb_array_elements(COALESCE(p_images, '[]'::jsonb))
  LOOP
    v_idx := v_idx + 1;
    IF v_idx > 9 THEN
      EXIT;
    END IF;
    INSERT INTO public.reputation_post_images
      (post_id, image_url, image_storage_key, sort_order, is_before)
    VALUES (
      v_post_id,
      COALESCE(v_img->>'image_url', ''),
      NULLIF(v_img->>'image_storage_key', ''),
      v_idx - 1,
      COALESCE((v_img->>'is_before')::boolean, false)
    );
  END LOOP;

  RETURN jsonb_build_object('id', v_post_id, 'moderation_status', 'pending');
END;
$function$;

REVOKE ALL ON FUNCTION public.create_reputation_post(uuid, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_reputation_post(uuid, text, text, jsonb) TO authenticated;

-- 点赞切换，维护 like_count，并给作者发站内通知
CREATE OR REPLACE FUNCTION public.toggle_reputation_like(p_post_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_author uuid;
  v_title text;
  v_nickname text;
  v_liked boolean;
  v_like_count integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再点赞' USING ERRCODE = '42501';
  END IF;

  SELECT author_user_id, title INTO v_author, v_title
  FROM public.reputation_posts WHERE id = p_post_id;

  IF v_author IS NULL THEN
    RAISE EXCEPTION '帖子不存在' USING ERRCODE = 'P0002';
  END IF;

  IF EXISTS (SELECT 1 FROM public.reputation_likes WHERE post_id = p_post_id AND user_id = v_uid) THEN
    DELETE FROM public.reputation_likes WHERE post_id = p_post_id AND user_id = v_uid;
    UPDATE public.reputation_posts SET like_count = GREATEST(like_count - 1, 0), updated_at = now() WHERE id = p_post_id;
    v_liked := false;
  ELSE
    INSERT INTO public.reputation_likes (post_id, user_id) VALUES (p_post_id, v_uid);
    UPDATE public.reputation_posts SET like_count = like_count + 1, updated_at = now() WHERE id = p_post_id;
    v_liked := true;
  END IF;

  SELECT like_count INTO v_like_count FROM public.reputation_posts WHERE id = p_post_id;

  IF v_liked AND v_author IS DISTINCT FROM v_uid THEN
    SELECT COALESCE(nickname, '用户') INTO v_nickname FROM public.profiles WHERE id = v_uid;
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_author,
      'reputation_like',
      '你的口碑帖子收到点赞',
      v_nickname || ' 赞了你的帖子「' || v_title || '」',
      jsonb_build_object('post_id', p_post_id)
    );
  END IF;

  RETURN jsonb_build_object('liked', v_liked, 'like_count', v_like_count);
END;
$function$;

REVOKE ALL ON FUNCTION public.toggle_reputation_like(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.toggle_reputation_like(uuid) TO authenticated;

-- 评论，维护 comment_count，并给作者发站内通知
CREATE OR REPLACE FUNCTION public.add_reputation_comment(p_post_id uuid, p_content text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_author uuid;
  v_title text;
  v_comment_id uuid;
  v_nickname text;
  v_avatar text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再评论' USING ERRCODE = '42501';
  END IF;

  SELECT author_user_id, title INTO v_author, v_title
  FROM public.reputation_posts WHERE id = p_post_id;

  IF v_author IS NULL THEN
    RAISE EXCEPTION '帖子不存在' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.reputation_comments (post_id, user_id, content)
  VALUES (p_post_id, v_uid, btrim(p_content))
  RETURNING id INTO v_comment_id;

  UPDATE public.reputation_posts SET comment_count = comment_count + 1, updated_at = now()
  WHERE id = p_post_id;

  SELECT COALESCE(nickname, '用户'), avatar_url INTO v_nickname, v_avatar
  FROM public.profiles WHERE id = v_uid;

  IF v_author IS DISTINCT FROM v_uid THEN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
      v_author,
      'reputation_comment',
      '你的口碑帖子收到评论',
      v_nickname || ' 评论了你的帖子「' || v_title || '」',
      jsonb_build_object('post_id', p_post_id)
    );
  END IF;

  RETURN jsonb_build_object(
    'id', v_comment_id,
    'content', btrim(p_content),
    'nickname', v_nickname,
    'avatar_url', v_avatar,
    'created_at', now()
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.add_reputation_comment(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_reputation_comment(uuid, text) TO authenticated;

-- 我发布的帖子（任意状态，带状态供作者跟踪审核进度）
CREATE OR REPLACE FUNCTION public.list_my_reputation_posts(
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
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
      p.title,
      p.content,
      p.like_count,
      p.comment_count,
      p.moderation_status,
      p.review_note,
      p.created_at,
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('image_url', i.image_url, 'is_before', i.is_before) ORDER BY i.sort_order)
        FROM public.reputation_post_images i
        WHERE i.post_id = p.id
      ), '[]'::jsonb) AS images
    FROM public.reputation_posts p
    WHERE p.author_user_id = v_uid
    ORDER BY p.created_at DESC, p.id
    LIMIT v_limit OFFSET v_offset
  ) item;

  RETURN jsonb_build_object('total', v_total, 'posts', v_posts);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_my_reputation_posts(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_reputation_posts(integer, integer) TO authenticated;