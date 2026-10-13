-- 评论表：支持商户代发（署名/匿名）、审计来源与创建人
ALTER TABLE public.reputation_comments
  ALTER COLUMN user_id DROP NOT NULL;

ALTER TABLE public.reputation_comments
  ADD COLUMN author_display_name text,
  ADD COLUMN is_anonymous boolean NOT NULL DEFAULT false,
  ADD COLUMN created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN source text NOT NULL DEFAULT 'user';

ALTER TABLE public.reputation_comments
  ADD CONSTRAINT reputation_comments_author_name_check
  CHECK (author_display_name IS NULL OR char_length(btrim(author_display_name)) BETWEEN 1 AND 30);

ALTER TABLE public.reputation_comments
  ADD CONSTRAINT reputation_comments_source_check
  CHECK (source IN ('user', 'merchant_admin'));

-- 后台评论列表（分页，按帖子归属校验；昵称/头像按统一显示规则算好）
CREATE OR REPLACE FUNCTION public.list_enterprise_reputation_comments(
  p_post_id uuid,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_post_root uuid;
  v_root uuid;
  v_comments jsonb;
  v_total integer;
  v_limit integer;
  v_offset integer;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT root_manager_id INTO v_post_root
  FROM public.reputation_posts
  WHERE id = p_post_id;

  IF v_post_root IS NULL THEN
    RAISE EXCEPTION '笔记不存在或已被删除' USING ERRCODE = '42501';
  END IF;

  IF public.is_admin(v_caller) THEN
    v_root := v_post_root;
  ELSE
    v_root := public.get_enterprise_root_manager_id(v_caller);
    IF v_root IS DISTINCT FROM v_post_root THEN
      RAISE EXCEPTION '无权查看该笔记的评论' USING ERRCODE = '42501';
    END IF;
  END IF;

  v_limit := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  v_offset := LEAST(GREATEST(COALESCE(p_offset, 0), 0), 10000);

  SELECT COUNT(*) INTO v_total
  FROM public.reputation_comments c
  WHERE c.post_id = p_post_id;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', c.id,
        'content', c.content,
        'nickname', CASE
          WHEN c.is_anonymous THEN '匿名用户'
          WHEN NULLIF(btrim(c.author_display_name), '') IS NOT NULL THEN btrim(c.author_display_name)
          ELSE COALESCE(pr.nickname, '用户')
        END,
        'avatar_url', CASE
          WHEN c.is_anonymous OR NULLIF(btrim(c.author_display_name), '') IS NOT NULL THEN NULL
          ELSE pr.avatar_url
        END,
        'is_anonymous', COALESCE(c.is_anonymous, false),
        'source', c.source,
        'created_at', c.created_at
      )
      ORDER BY c.created_at DESC, c.id
    ),
    '[]'::jsonb
  ) INTO v_comments
  FROM (
    SELECT * FROM public.reputation_comments
    WHERE post_id = p_post_id
    ORDER BY created_at DESC, id
    LIMIT v_limit OFFSET v_offset
  ) c
  LEFT JOIN public.profiles pr ON pr.id = c.user_id;

  RETURN jsonb_build_object('comments', v_comments, 'total', v_total);
END;
$function$;

-- 商户代发评论：匿名强制置空名称；非匿名名称 1-30 字必填
CREATE OR REPLACE FUNCTION public.merchant_create_reputation_comment(
  p_post_id uuid,
  p_content text,
  p_author_name text DEFAULT NULL,
  p_is_anonymous boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_post_root uuid;
  v_root uuid;
  v_content text;
  v_author text;
  v_anonymous boolean := COALESCE(p_is_anonymous, false);
  v_comment_id uuid;
  v_comment jsonb;
  v_comment_count integer;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT root_manager_id INTO v_post_root
  FROM public.reputation_posts
  WHERE id = p_post_id;

  IF v_post_root IS NULL THEN
    RAISE EXCEPTION '笔记不存在或已被删除' USING ERRCODE = '42501';
  END IF;

  IF public.is_admin(v_caller) THEN
    v_root := v_post_root;
  ELSE
    v_root := public.get_enterprise_root_manager_id(v_caller);
    IF v_root IS DISTINCT FROM v_post_root THEN
      RAISE EXCEPTION '无权在该笔记下发布评论' USING ERRCODE = '42501';
    END IF;
    IF NOT public.has_enterprise_permission('reputation', v_caller) THEN
      RAISE EXCEPTION '当前角色没有「达人口碑」权限，请联系企业管理员开通' USING ERRCODE = '42501';
    END IF;
  END IF;

  v_content := btrim(p_content);
  IF v_content IS NULL OR char_length(v_content) = 0 THEN
    RAISE EXCEPTION '评论内容不能为空' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_content) > 500 THEN
    RAISE EXCEPTION '评论内容不能超过 500 字' USING ERRCODE = '22023';
  END IF;

  IF v_anonymous THEN
    v_author := NULL;
  ELSE
    v_author := NULLIF(btrim(p_author_name), '');
    IF v_author IS NULL OR char_length(v_author) > 30 THEN
      RAISE EXCEPTION '请填写评论者名称（1-30 字）' USING ERRCODE = '22023';
    END IF;
  END IF;

  INSERT INTO public.reputation_comments (
    post_id, user_id, content, author_display_name, is_anonymous, created_by, source
  ) VALUES (
    p_post_id, NULL, v_content, v_author, v_anonymous, v_caller, 'merchant_admin'
  ) RETURNING id INTO v_comment_id;

  UPDATE public.reputation_posts
     SET comment_count = COALESCE(comment_count, 0) + 1,
         updated_at = now()
   WHERE id = p_post_id
  RETURNING comment_count INTO v_comment_count;

  SELECT jsonb_build_object(
    'id', c.id,
    'content', c.content,
    'nickname', CASE WHEN c.is_anonymous THEN '匿名用户' ELSE btrim(c.author_display_name) END,
    'avatar_url', NULL,
    'is_anonymous', c.is_anonymous,
    'source', c.source,
    'created_at', c.created_at
  ) INTO v_comment
  FROM public.reputation_comments c
  WHERE c.id = v_comment_id;

  RETURN jsonb_build_object('comment', v_comment, 'comment_count', v_comment_count);
END;
$function$;

-- 单条删除评论：先验归属，删除后原子递减评论数
CREATE OR REPLACE FUNCTION public.delete_reputation_comment(
  p_comment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_post_id uuid;
  v_post_root uuid;
  v_root uuid;
  v_comment_count integer;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  SELECT c.post_id, p.root_manager_id
    INTO v_post_id, v_post_root
  FROM public.reputation_comments c
  JOIN public.reputation_posts p ON p.id = c.post_id
  WHERE c.id = p_comment_id;

  IF v_post_id IS NULL THEN
    RAISE EXCEPTION '评论不存在或已被删除' USING ERRCODE = '42501';
  END IF;

  IF public.is_admin(v_caller) THEN
    v_root := v_post_root;
  ELSE
    v_root := public.get_enterprise_root_manager_id(v_caller);
    IF v_root IS DISTINCT FROM v_post_root THEN
      RAISE EXCEPTION '无权删除该评论' USING ERRCODE = '42501';
    END IF;
    IF NOT public.has_enterprise_permission('reputation', v_caller) THEN
      RAISE EXCEPTION '当前角色没有「达人口碑」权限，请联系企业管理员开通' USING ERRCODE = '42501';
    END IF;
  END IF;

  DELETE FROM public.reputation_comments
  WHERE id = p_comment_id;

  UPDATE public.reputation_posts
     SET comment_count = GREATEST(COALESCE(comment_count, 0) - 1, 0),
         updated_at = now()
   WHERE id = v_post_id
  RETURNING comment_count INTO v_comment_count;

  RETURN jsonb_build_object(
    'id', p_comment_id,
    'post_id', v_post_id,
    'comment_count', COALESCE(v_comment_count, 0)
  );
END;
$function$;

-- 公开详情：评论昵称/头像按统一规则（匿名 → 署名 → 用户昵称）
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
      jsonb_build_object(
        'id', c.id,
        'content', c.content,
        'nickname', CASE
          WHEN c.is_anonymous THEN '匿名用户'
          WHEN NULLIF(btrim(c.author_display_name), '') IS NOT NULL THEN btrim(c.author_display_name)
          ELSE COALESCE(pr2.nickname, '用户')
        END,
        'avatar_url', CASE
          WHEN c.is_anonymous OR NULLIF(btrim(c.author_display_name), '') IS NOT NULL THEN NULL
          ELSE pr2.avatar_url
        END,
        'created_at', c.created_at
      )
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

-- 权限：三个新后台接口只给登录用户，收回匿名
REVOKE ALL ON FUNCTION public.list_enterprise_reputation_comments(uuid, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_enterprise_reputation_comments(uuid, integer, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.merchant_create_reputation_comment(uuid, text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.merchant_create_reputation_comment(uuid, text, text, boolean) TO authenticated;

REVOKE ALL ON FUNCTION public.delete_reputation_comment(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_reputation_comment(uuid) TO authenticated;