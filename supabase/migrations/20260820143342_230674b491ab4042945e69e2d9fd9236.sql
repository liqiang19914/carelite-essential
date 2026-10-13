-- 代码审查修复（口碑初始点赞链路）：
-- 1) [P1 权限缺口] set_reputation_post_display 非管理员分支补 has_enterprise_permission('reputation')，
--    与 merchant_create/update_reputation_post 保持一致；平台管理员分支不变。
-- 2) [P1 契约] merchant_create/update_reputation_post 返回体补 like_count（真实 + 初始合成），对齐计划 C.5。

CREATE OR REPLACE FUNCTION public.set_reputation_post_display(
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

  IF NOT public.is_admin(auth.uid()) THEN
    IF public.get_enterprise_root_manager_id(auth.uid()) IS DISTINCT FROM v_root THEN
      RAISE EXCEPTION '无权操作该笔记' USING ERRCODE = '42501';
    END IF;
    IF NOT public.has_enterprise_permission('reputation', auth.uid()) THEN
      RAISE EXCEPTION '当前角色没有「达人口碑」权限，请联系企业管理员开通' USING ERRCODE = '42501';
    END IF;
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
  v_like_count integer;
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
  v_content_doc jsonb := CASE
    WHEN jsonb_typeof(p_content_doc) = 'object' THEN p_content_doc
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

  IF NOT public.has_enterprise_permission('reputation', auth.uid()) THEN
    RAISE EXCEPTION '当前角色没有「达人口碑」权限，请联系企业管理员开通' USING ERRCODE = '42501';
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

  IF v_content_doc IS NOT NULL
     AND octet_length(v_content_doc::text) > 262144 THEN
    RAISE EXCEPTION '正文内容过大，请减少图片或分段发布' USING ERRCODE = 'P0001';
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
    v_root, p_category_id, auth.uid(), v_title, v_content, v_content_doc,
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

  SELECT COALESCE(like_count, 0) + COALESCE(base_like_count, 0)
    INTO v_like_count
  FROM public.reputation_posts WHERE id = v_post_id;

  RETURN jsonb_build_object(
    'id', v_post_id,
    'moderation_status', 'passed',
    'post_type', v_type,
    'cover_layout', v_layout,
    'like_count', COALESCE(v_like_count, 0)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.merchant_create_reputation_post(text, text, jsonb, text, uuid, jsonb, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.merchant_create_reputation_post(text, text, jsonb, text, uuid, jsonb, text, text, jsonb) TO authenticated;

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
  v_content_doc jsonb := CASE
    WHEN jsonb_typeof(p_content_doc) = 'object' THEN p_content_doc
    ELSE NULL
  END;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row
  FROM public.reputation_posts
  WHERE id = p_post_id
  FOR UPDATE;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION '帖子不存在' USING ERRCODE = 'P0002';
  END IF;

  v_root := v_row.root_manager_id;
  IF NOT public.is_admin(auth.uid()) THEN
    IF public.get_enterprise_root_manager_id(auth.uid()) IS DISTINCT FROM v_root THEN
      RAISE EXCEPTION '无权编辑该帖子' USING ERRCODE = '42501';
    END IF;
    IF NOT public.has_enterprise_permission('reputation', auth.uid()) THEN
      RAISE EXCEPTION '当前角色没有「达人口碑」权限，请联系企业管理员开通' USING ERRCODE = '42501';
    END IF;
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

  IF v_content_doc IS NOT NULL
     AND octet_length(v_content_doc::text) > 262144 THEN
    RAISE EXCEPTION '正文内容过大，请减少图片或分段保存' USING ERRCODE = 'P0001';
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
         content_doc = v_content_doc,
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

  DELETE FROM public.reputation_post_images WHERE post_id = p_post_id;
  IF v_type = 'image' THEN
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
  END IF;

  RETURN jsonb_build_object(
    'id', p_post_id,
    'editorial_updated_at', now(),
    'moderation_status', v_row.moderation_status,
    'like_count', COALESCE(v_row.like_count, 0) + COALESCE(v_row.base_like_count, 0)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.merchant_update_reputation_post(uuid, timestamptz, text, text, jsonb, text, uuid, jsonb, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.merchant_update_reputation_post(uuid, timestamptz, text, text, jsonb, text, uuid, jsonb, text, text, jsonb) TO authenticated;