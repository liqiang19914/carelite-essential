-- 口碑初始点赞（小红心补量）：镜像 base_view_count 的既有模式
-- 展示点赞 = like_count(真实) + base_like_count(商户设定)；真实点赞继续在 like_count 上累加
-- 1) 新列 + 约束 + 注释
-- 2) set_reputation_post_display 扩为 7 参（新增初始点赞与并发期望值；DROP 旧签名避免 PostgREST 重载歧义）
-- 3) 四个读取口 like_count 合成；toggle_reputation_like 返回合成值（点赞后客户端展示不跳水）

ALTER TABLE public.reputation_posts
  ADD COLUMN IF NOT EXISTS base_like_count integer NOT NULL DEFAULT 0;

ALTER TABLE public.reputation_posts
  DROP CONSTRAINT IF EXISTS reputation_posts_base_like_count_check;
ALTER TABLE public.reputation_posts
  ADD CONSTRAINT reputation_posts_base_like_count_check
  CHECK (base_like_count >= 0 AND base_like_count <= 100000000);

COMMENT ON COLUMN public.reputation_posts.base_like_count IS '商户设定的初始点赞数；展示点赞 = like_count + base_like_count';

DROP FUNCTION IF EXISTS public.set_reputation_post_display(uuid, integer, boolean, integer, boolean);

CREATE FUNCTION public.set_reputation_post_display(
  p_post_id uuid,
  p_base_view_count integer DEFAULT NULL,
  p_is_pinned boolean DEFAULT NULL,
  p_expected_base_view_count integer DEFAULT NULL,
  p_expected_is_pinned boolean DEFAULT NULL,
  p_base_like_count integer DEFAULT NULL,
  p_expected_base_like_count integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_next_rank integer := 0;
  v_row public.reputation_posts;
  v_cur_base integer;
  v_cur_pinned boolean;
  v_cur_base_like integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT root_manager_id, base_view_count, is_pinned, base_like_count
    INTO v_root, v_cur_base, v_cur_pinned, v_cur_base_like
  FROM public.reputation_posts WHERE id = p_post_id
  FOR UPDATE;

  IF v_root IS NULL THEN
    RAISE EXCEPTION '笔记不存在' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.is_admin(auth.uid())
     AND public.get_enterprise_root_manager_id(auth.uid()) IS DISTINCT FROM v_root THEN
    RAISE EXCEPTION '无权操作该笔记' USING ERRCODE = '42501';
  END IF;

  IF p_base_view_count IS NOT NULL AND p_base_view_count < 0 THEN
    RAISE EXCEPTION '初始阅读量不能小于 0' USING ERRCODE = 'P0002';
  END IF;
  IF p_base_like_count IS NOT NULL AND p_base_like_count < 0 THEN
    RAISE EXCEPTION '初始点赞数不能小于 0' USING ERRCODE = 'P0002';
  END IF;

  IF p_expected_base_view_count IS NOT NULL
     AND v_cur_base IS DISTINCT FROM p_expected_base_view_count THEN
    RAISE EXCEPTION '这条笔记刚被同事改过，请刷新后重试' USING ERRCODE = 'P0002';
  END IF;
  IF p_expected_is_pinned IS NOT NULL
     AND v_cur_pinned IS DISTINCT FROM p_expected_is_pinned THEN
    RAISE EXCEPTION '这条笔记刚被同事改过，请刷新后重试' USING ERRCODE = 'P0002';
  END IF;
  IF p_expected_base_like_count IS NOT NULL
     AND v_cur_base_like IS DISTINCT FROM p_expected_base_like_count THEN
    RAISE EXCEPTION '这条笔记刚被同事改过，请刷新后重试' USING ERRCODE = 'P0002';
  END IF;

  IF p_is_pinned IS TRUE THEN
    SELECT COALESCE(MAX(pinned_rank), 0) + 1 INTO v_next_rank
    FROM public.reputation_posts
    WHERE root_manager_id = v_root;
  END IF;

  UPDATE public.reputation_posts
     SET base_view_count = COALESCE(p_base_view_count, base_view_count),
         base_like_count = COALESCE(p_base_like_count, base_like_count),
         is_pinned = COALESCE(p_is_pinned, is_pinned),
         pinned_rank = CASE
           WHEN p_is_pinned IS TRUE THEN v_next_rank
           WHEN p_is_pinned IS FALSE THEN 0
           ELSE pinned_rank
         END,
         updated_at = now()
   WHERE id = p_post_id
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION '笔记不存在' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'base_view_count', v_row.base_view_count,
    'base_like_count', v_row.base_like_count,
    'is_pinned', v_row.is_pinned,
    'pinned_rank', v_row.pinned_rank,
    'view_count', COALESCE(v_row.view_count, 0) + COALESCE(v_row.base_view_count, 0),
    'like_count', COALESCE(v_row.like_count, 0) + COALESCE(v_row.base_like_count, 0)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.set_reputation_post_display(uuid, integer, boolean, integer, boolean, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_reputation_post_display(uuid, integer, boolean, integer, boolean, integer, integer) TO authenticated;

-- 公开列表：点赞按真实 + 初始合成
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
      COALESCE(p.like_count, 0) + COALESCE(p.base_like_count, 0) AS like_count,
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
      COALESCE(NULLIF(btrim(p.author_display_name), ''), pr.nickname) AS author_name,
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

-- 公开详情：点赞按真实 + 初始合成
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
      'content_doc', p.content_doc,
      'like_count', COALESCE(p.like_count, 0) + COALESCE(p.base_like_count, 0),
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
      'author_name', COALESCE(NULLIF(btrim(p.author_display_name), ''), pr.nickname),
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

-- 我的笔记：点赞按真实 + 初始合成
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
      p.content_doc,
      COALESCE(p.like_count, 0) + COALESCE(p.base_like_count, 0) AS like_count,
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
      COALESCE(NULLIF(btrim(p.author_display_name), ''), pr.nickname) AS author_name,
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('image_url', i.image_url, 'is_before', i.is_before) ORDER BY i.sort_order)
        FROM public.reputation_post_images i
        WHERE i.post_id = p.id
      ), '[]'::jsonb) AS images
    FROM public.reputation_posts p
    LEFT JOIN public.reputation_categories c ON c.id = p.category_id
    LEFT JOIN public.profiles pr ON pr.id = p.author_user_id
    WHERE p.author_user_id = v_uid
    ORDER BY p.created_at DESC, p.id
    LIMIT v_limit OFFSET v_offset
  ) item;

  RETURN jsonb_build_object('total', v_total, 'posts', v_posts);
END;
$function$;

-- 商户列表：点赞按真实 + 初始合成，并返回初始值原值（设置对话框预填与「含初始 N」标注）
CREATE OR REPLACE FUNCTION public.list_enterprise_reputation_posts(
  p_root_manager_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0,
  p_status text DEFAULT NULL,
  p_search text DEFAULT NULL
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
  v_status text := NULLIF(btrim(COALESCE(p_status, '')), '');
  v_search text := NULLIF(btrim(COALESCE(p_search, '')), '');
  v_like text;
BEGIN
  IF public.is_admin(auth.uid()) THEN
    v_root := p_root_manager_id;
  ELSE
    v_root := public.get_enterprise_root_manager_id(auth.uid());
  END IF;

  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限或未指定企业' USING ERRCODE = '42501';
  END IF;

  IF v_status IS NOT NULL
     AND v_status NOT IN ('pending', 'passed', 'flagged', 'manual_review', 'blocked') THEN
    RAISE EXCEPTION '不支持的审核状态' USING ERRCODE = 'P0001';
  END IF;

  IF v_search IS NOT NULL THEN
    v_like := '%' || replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM public.reputation_posts p
  LEFT JOIN public.profiles pr ON pr.id = p.author_user_id
  WHERE p.root_manager_id = v_root
    AND (v_status IS NULL OR p.moderation_status = v_status)
    AND (
      v_like IS NULL
      OR p.title ILIKE v_like ESCAPE '\'
      OR p.content ILIKE v_like ESCAPE '\'
      OR COALESCE(pr.nickname, '') ILIKE v_like ESCAPE '\'
      OR COALESCE(p.author_display_name, '') ILIKE v_like ESCAPE '\'
    );

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
      p.content_doc,
      p.author_display_name,
      p.author_user_id,
      p.editorial_updated_at,
      COALESCE(p.like_count, 0) + COALESCE(p.base_like_count, 0) AS like_count,
      COALESCE(p.base_like_count, 0) AS base_like_count,
      p.comment_count,
      p.moderation_status,
      p.review_note,
      p.created_at,
      p.post_type,
      p.cover_layout,
      p.video_url,
      p.video_storage_key,
      p.video_cover_url,
      p.video_duration_seconds,
      COALESCE(p.is_pinned, false) AS is_pinned,
      COALESCE(p.pinned_rank, 0) AS pinned_rank,
      COALESCE(p.base_view_count, 0) AS base_view_count,
      COALESCE(p.view_count, 0) + COALESCE(p.base_view_count, 0) AS view_count,
      COALESCE(NULLIF(btrim(p.author_display_name), ''), pr.nickname) AS author_name,
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('image_url', i.image_url, 'image_storage_key', i.image_storage_key, 'is_before', i.is_before) ORDER BY i.sort_order)
        FROM public.reputation_post_images i
        WHERE i.post_id = p.id
      ), '[]'::jsonb) AS images
    FROM public.reputation_posts p
    LEFT JOIN public.reputation_categories c ON c.id = p.category_id
    LEFT JOIN public.profiles pr ON pr.id = p.author_user_id
    WHERE p.root_manager_id = v_root
      AND (v_status IS NULL OR p.moderation_status = v_status)
      AND (
        v_like IS NULL
        OR p.title ILIKE v_like ESCAPE '\'
        OR p.content ILIKE v_like ESCAPE '\'
        OR COALESCE(pr.nickname, '') ILIKE v_like ESCAPE '\'
        OR COALESCE(p.author_display_name, '') ILIKE v_like ESCAPE '\'
      )
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

-- 点赞切换：返回合成点赞数（真实 + 初始），客户端点赞后展示不跳水
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

  SELECT COALESCE(like_count, 0) + COALESCE(base_like_count, 0)
    INTO v_like_count
  FROM public.reputation_posts WHERE id = p_post_id;

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