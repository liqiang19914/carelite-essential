-- 达人口碑：商户创建/编辑能力
-- 1) 新增富文本正文、展示署名、编辑时间戳（编辑乐观锁专用，点赞评论不触碰）
-- 2) 商户创建：免审直发（passed），署名可手填
-- 3) 商户编辑：本企业任意帖子，直接生效，不改审核状态/作者/计数
-- 4) 四个读取口同步返回新字段

ALTER TABLE public.reputation_posts
  ADD COLUMN IF NOT EXISTS content_doc jsonb,
  ADD COLUMN IF NOT EXISTS author_display_name text,
  ADD COLUMN IF NOT EXISTS editorial_updated_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.reputation_posts
  DROP CONSTRAINT IF EXISTS reputation_posts_author_display_name_len;
ALTER TABLE public.reputation_posts
  ADD CONSTRAINT reputation_posts_author_display_name_len
  CHECK (author_display_name IS NULL OR char_length(btrim(author_display_name)) BETWEEN 1 AND 30);

COMMENT ON COLUMN public.reputation_posts.content_doc IS '富文本正文（Tiptap JSON）。为空时按 content 纯文本渲染；content 始终是纯文本摘要，用于搜索与字数约束。';
COMMENT ON COLUMN public.reputation_posts.author_display_name IS '商户代发时的展示署名（1-30 字），优先于作者昵称展示。';
COMMENT ON COLUMN public.reputation_posts.editorial_updated_at IS '内容编辑时间戳：仅创建/编辑正文、分类、媒体、署名时推进，用于商户编辑的乐观锁。点赞、评论、置顶、阅读量不影响它。';

-- 商户创建口碑：免审直发
CREATE OR REPLACE FUNCTION public.merchant_create_reputation_post(
  p_title text,
  p_content text,
  p_content_doc jsonb DEFAULT NULL,
  p_author_display_name text DEFAULT NULL,
  p_category_id uuid DEFAULT NULL,
  p_images jsonb DEFAULT '[]'::jsonb,
  p_post_type text DEFAULT 'image',
  p_cover_layout text DEFAULT 'grid',
  p_video jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_post_id uuid;
  v_img jsonb;
  v_idx integer := 0;
  v_img_count integer;
  v_title text := btrim(COALESCE(p_title, ''));
  v_content text := btrim(COALESCE(p_content, ''));
  v_author text := NULLIF(btrim(COALESCE(p_author_display_name, '')), '');
  v_type text := lower(COALESCE(NULLIF(btrim(p_post_type), ''), 'image'));
  v_layout text := lower(COALESCE(NULLIF(btrim(p_cover_layout), ''), 'grid'));
  v_video_url text := NULLIF(btrim(COALESCE(p_video->>'video_url', '')), '');
  v_video_key text := NULLIF(btrim(COALESCE(p_video->>'video_storage_key', '')), '');
  v_video_cover text := NULLIF(btrim(COALESCE(p_video->>'video_cover_url', '')), '');
  v_video_seconds integer := CASE
    WHEN COALESCE(p_video->>'video_duration_seconds', '') ~ '^[0-9]+$'
      THEN (p_video->>'video_duration_seconds')::integer
    ELSE NULL
  END;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  IF public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '平台管理员请指定企业后使用编辑功能，创建口碑请用商户账号' USING ERRCODE = '42501';
  END IF;

  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限：当前账号不属于任何企业' USING ERRCODE = '42501';
  END IF;

  IF char_length(v_title) < 1 OR char_length(v_title) > 50 THEN
    RAISE EXCEPTION '标题需要 1-50 个字' USING ERRCODE = 'P0001';
  END IF;
  IF char_length(v_content) < 1 OR char_length(v_content) > 2000 THEN
    RAISE EXCEPTION '正文需要 1-2000 个字' USING ERRCODE = 'P0001';
  END IF;
  IF v_author IS NOT NULL AND char_length(v_author) > 30 THEN
    RAISE EXCEPTION '作者名称最多 30 个字' USING ERRCODE = 'P0001';
  END IF;

  IF p_content_doc IS NOT NULL THEN
    IF jsonb_typeof(p_content_doc) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION '正文格式不正确，请重新编辑' USING ERRCODE = 'P0001';
    END IF;
    IF octet_length(p_content_doc::text) > 262144 THEN
      RAISE EXCEPTION '正文内容过大，请减少图片或分段发布' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF v_type NOT IN ('image', 'video') THEN
    RAISE EXCEPTION '笔记类型只能是图文或视频' USING ERRCODE = 'P0002';
  END IF;
  IF v_layout NOT IN ('single', 'triple', 'grid') THEN
    v_layout := 'grid';
  END IF;
  IF v_type = 'video' AND v_video_url IS NULL THEN
    RAISE EXCEPTION '视频笔记需要先上传视频' USING ERRCODE = 'P0002';
  END IF;

  v_img_count := jsonb_array_length(COALESCE(p_images, '[]'::jsonb));
  IF v_type = 'video' AND v_img_count > 0 THEN
    RAISE EXCEPTION '视频笔记不能再添加配图' USING ERRCODE = 'P0001';
  END IF;
  IF v_type = 'image' AND v_img_count < 1 THEN
    RAISE EXCEPTION '图文笔记至少需要 1 张配图' USING ERRCODE = 'P0001';
  END IF;
  IF v_img_count > 9 THEN
    RAISE EXCEPTION '配图最多 9 张' USING ERRCODE = 'P0001';
  END IF;

  IF p_category_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.reputation_categories
      WHERE id = p_category_id AND root_manager_id = v_root
    ) THEN
      RAISE EXCEPTION '所选分类不存在' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  INSERT INTO public.reputation_posts (
    root_manager_id, category_id, author_user_id, title, content, content_doc,
    author_display_name, post_type, cover_layout,
    video_url, video_storage_key, video_cover_url, video_duration_seconds,
    moderation_status, editorial_updated_at
  )
  VALUES (
    v_root, p_category_id, auth.uid(), v_title, v_content,
    CASE WHEN p_content_doc IS NOT NULL THEN p_content_doc ELSE NULL END,
    v_author, v_type, v_layout,
    CASE WHEN v_type = 'video' THEN v_video_url ELSE NULL END,
    CASE WHEN v_type = 'video' THEN v_video_key ELSE NULL END,
    CASE WHEN v_type = 'video' THEN v_video_cover ELSE NULL END,
    CASE WHEN v_type = 'video' THEN v_video_seconds ELSE NULL END,
    'passed', now()
  )
  RETURNING id INTO v_post_id;

  FOR v_img IN SELECT * FROM jsonb_array_elements(COALESCE(p_images, '[]'::jsonb))
  LOOP
    v_idx := v_idx + 1;
    IF NULLIF(btrim(COALESCE(v_img->>'image_url', '')), '') IS NULL THEN
      RAISE EXCEPTION '第 % 张配图地址为空，请重新上传', v_idx USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO public.reputation_post_images
      (post_id, image_url, image_storage_key, sort_order, is_before)
    VALUES (
      v_post_id,
      v_img->>'image_url',
      NULLIF(v_img->>'image_storage_key', ''),
      v_idx - 1,
      COALESCE((v_img->>'is_before')::boolean, false)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'id', v_post_id,
    'moderation_status', 'passed',
    'post_type', v_type,
    'cover_layout', v_layout
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.merchant_create_reputation_post(text, text, jsonb, text, uuid, jsonb, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.merchant_create_reputation_post(text, text, jsonb, text, uuid, jsonb, text, text, jsonb) TO authenticated;

-- 商户编辑口碑：本企业任意帖子（含客户发的），直接生效，不动审核状态与作者
CREATE OR REPLACE FUNCTION public.merchant_update_reputation_post(
  p_post_id uuid,
  p_expected_updated_at timestamptz,
  p_title text,
  p_content text,
  p_content_doc jsonb DEFAULT NULL,
  p_author_display_name text DEFAULT NULL,
  p_category_id uuid DEFAULT NULL,
  p_images jsonb DEFAULT '[]'::jsonb,
  p_post_type text DEFAULT 'image',
  p_cover_layout text DEFAULT 'grid',
  p_video jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_row public.reputation_posts;
  v_img jsonb;
  v_idx integer := 0;
  v_img_count integer;
  v_title text := btrim(COALESCE(p_title, ''));
  v_content text := btrim(COALESCE(p_content, ''));
  v_author text := NULLIF(btrim(COALESCE(p_author_display_name, '')), '');
  v_type text := lower(COALESCE(NULLIF(btrim(p_post_type), ''), 'image'));
  v_layout text := lower(COALESCE(NULLIF(btrim(p_cover_layout), ''), 'grid'));
  v_video_url text := NULLIF(btrim(COALESCE(p_video->>'video_url', '')), '');
  v_video_key text := NULLIF(btrim(COALESCE(p_video->>'video_storage_key', '')), '');
  v_video_cover text := NULLIF(btrim(COALESCE(p_video->>'video_cover_url', '')), '');
  v_video_seconds integer := CASE
    WHEN COALESCE(p_video->>'video_duration_seconds', '') ~ '^[0-9]+$'
      THEN (p_video->>'video_duration_seconds')::integer
    ELSE NULL
  END;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  -- 先锁行再校验：预检查与写入之间不留并发窗口
  SELECT * INTO v_row
  FROM public.reputation_posts
  WHERE id = p_post_id
  FOR UPDATE;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION '帖子不存在' USING ERRCODE = 'P0002';
  END IF;

  v_root := v_row.root_manager_id;
  IF NOT public.is_admin(auth.uid())
     AND public.get_enterprise_root_manager_id(auth.uid()) IS DISTINCT FROM v_root THEN
    RAISE EXCEPTION '无权编辑该帖子' USING ERRCODE = '42501';
  END IF;

  IF p_expected_updated_at IS NULL THEN
    RAISE EXCEPTION '内容版本缺失，请刷新后重新编辑' USING ERRCODE = 'P0001';
  END IF;
  IF v_row.editorial_updated_at IS DISTINCT FROM p_expected_updated_at THEN
    RAISE EXCEPTION '内容已被其他人修改，请刷新后再编辑' USING ERRCODE = 'P0001';
  END IF;

  IF char_length(v_title) < 1 OR char_length(v_title) > 50 THEN
    RAISE EXCEPTION '标题需要 1-50 个字' USING ERRCODE = 'P0001';
  END IF;
  IF char_length(v_content) < 1 OR char_length(v_content) > 2000 THEN
    RAISE EXCEPTION '正文需要 1-2000 个字' USING ERRCODE = 'P0001';
  END IF;
  IF v_author IS NOT NULL AND char_length(v_author) > 30 THEN
    RAISE EXCEPTION '作者名称最多 30 个字' USING ERRCODE = 'P0001';
  END IF;

  IF p_content_doc IS NOT NULL THEN
    IF jsonb_typeof(p_content_doc) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION '正文格式不正确，请重新编辑' USING ERRCODE = 'P0001';
    END IF;
    IF octet_length(p_content_doc::text) > 262144 THEN
      RAISE EXCEPTION '正文内容过大，请减少图片或分段保存' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF v_type NOT IN ('image', 'video') THEN
    RAISE EXCEPTION '笔记类型只能是图文或视频' USING ERRCODE = 'P0002';
  END IF;
  IF v_layout NOT IN ('single', 'triple', 'grid') THEN
    v_layout := 'grid';
  END IF;
  IF v_type = 'video' AND v_video_url IS NULL THEN
    RAISE EXCEPTION '视频笔记需要先上传视频' USING ERRCODE = 'P0002';
  END IF;

  v_img_count := jsonb_array_length(COALESCE(p_images, '[]'::jsonb));
  IF v_type = 'video' AND v_img_count > 0 THEN
    RAISE EXCEPTION '视频笔记不能再添加配图' USING ERRCODE = 'P0001';
  END IF;
  IF v_type = 'image' AND v_img_count < 1 THEN
    RAISE EXCEPTION '图文笔记至少需要 1 张配图' USING ERRCODE = 'P0001';
  END IF;
  IF v_img_count > 9 THEN
    RAISE EXCEPTION '配图最多 9 张' USING ERRCODE = 'P0001';
  END IF;

  IF p_category_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.reputation_categories
      WHERE id = p_category_id AND root_manager_id = v_root
    ) THEN
      RAISE EXCEPTION '所选分类不存在或已被删除' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  UPDATE public.reputation_posts
     SET title = v_title,
         content = v_content,
         content_doc = p_content_doc,
         author_display_name = v_author,
         category_id = p_category_id,
         post_type = v_type,
         cover_layout = v_layout,
         video_url = CASE WHEN v_type = 'video' THEN v_video_url ELSE NULL END,
         video_storage_key = CASE WHEN v_type = 'video' THEN v_video_key ELSE NULL END,
         video_cover_url = CASE WHEN v_type = 'video' THEN v_video_cover ELSE NULL END,
         video_duration_seconds = CASE WHEN v_type = 'video' THEN v_video_seconds ELSE NULL END,
         updated_at = now(),
         editorial_updated_at = now()
   WHERE id = p_post_id
     AND editorial_updated_at = p_expected_updated_at;

  IF NOT FOUND THEN
    RAISE EXCEPTION '内容已被其他人修改，请刷新后再编辑' USING ERRCODE = 'P0001';
  END IF;

  -- 图片集合整体替换：任一失败整次回滚
  IF v_type = 'image' THEN
    DELETE FROM public.reputation_post_images WHERE post_id = p_post_id;
    FOR v_img IN SELECT * FROM jsonb_array_elements(COALESCE(p_images, '[]'::jsonb))
    LOOP
      v_idx := v_idx + 1;
      IF NULLIF(btrim(COALESCE(v_img->>'image_url', '')), '') IS NULL THEN
        RAISE EXCEPTION '第 % 张配图地址为空，请重新上传', v_idx USING ERRCODE = 'P0001';
      END IF;
      INSERT INTO public.reputation_post_images
        (post_id, image_url, image_storage_key, sort_order, is_before)
      VALUES (
        p_post_id,
        v_img->>'image_url',
        NULLIF(v_img->>'image_storage_key', ''),
        v_idx - 1,
        COALESCE((v_img->>'is_before')::boolean, false)
      );
    END LOOP;
  ELSE
    DELETE FROM public.reputation_post_images WHERE post_id = p_post_id;
  END IF;

  RETURN jsonb_build_object(
    'id', p_post_id,
    'editorial_updated_at', now(),
    'moderation_status', v_row.moderation_status
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.merchant_update_reputation_post(uuid, timestamptz, text, text, jsonb, text, uuid, jsonb, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.merchant_update_reputation_post(uuid, timestamptz, text, text, jsonb, text, uuid, jsonb, text, text, jsonb) TO authenticated;

-- 公开列表：署名优先取商户代发署名
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

-- 公开详情：返回富文本与解析后的署名
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

-- 我的笔记：补富文本与署名
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

-- 商户列表（最新版带状态筛选与搜索）：补富文本、署名、作者 ID、编辑时间戳、媒体 storage key
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
      p.like_count,
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