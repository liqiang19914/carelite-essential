-- 发布笔记：支持图文（三种封面版式）与视频笔记
DROP FUNCTION IF EXISTS public.submit_reputation_post(uuid, text, text, uuid, jsonb);

CREATE OR REPLACE FUNCTION public.submit_reputation_post(
  p_manager_id uuid,
  p_title text,
  p_content text,
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
    RAISE EXCEPTION '请先登录后再发布' USING ERRCODE = '42501';
  END IF;

  v_root := public.get_enterprise_root_manager_id(p_manager_id);
  IF v_root IS NULL OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RAISE EXCEPTION '该商户尚未开放笔记' USING ERRCODE = 'P0002';
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

  IF p_category_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.reputation_categories
      WHERE id = p_category_id AND root_manager_id = v_root
    ) THEN
      RAISE EXCEPTION '所选分类不存在' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  INSERT INTO public.reputation_posts (
    root_manager_id, category_id, author_user_id, title, content,
    post_type, cover_layout,
    video_url, video_storage_key, video_cover_url, video_duration_seconds
  )
  VALUES (
    v_root, p_category_id, auth.uid(), btrim(p_title), btrim(p_content),
    v_type, v_layout,
    CASE WHEN v_type = 'video' THEN v_video_url ELSE NULL END,
    CASE WHEN v_type = 'video' THEN v_video_key ELSE NULL END,
    CASE WHEN v_type = 'video' THEN v_video_cover ELSE NULL END,
    CASE WHEN v_type = 'video' THEN v_video_seconds ELSE NULL END
  )
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

  RETURN jsonb_build_object(
    'id', v_post_id,
    'moderation_status', 'pending',
    'post_type', v_type,
    'cover_layout', v_layout
  );
END;
$function$;

-- 商户后台：设置初始阅读量 / 置顶（置顶次序取本品牌最大值 + 1）
CREATE OR REPLACE FUNCTION public.set_reputation_post_display(
  p_post_id uuid,
  p_base_view_count integer DEFAULT NULL,
  p_is_pinned boolean DEFAULT NULL
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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT root_manager_id INTO v_root
  FROM public.reputation_posts WHERE id = p_post_id;

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

  IF p_is_pinned IS TRUE THEN
    SELECT COALESCE(MAX(pinned_rank), 0) + 1 INTO v_next_rank
    FROM public.reputation_posts
    WHERE root_manager_id = v_root;
  END IF;

  UPDATE public.reputation_posts
     SET base_view_count = COALESCE(p_base_view_count, base_view_count),
         is_pinned = COALESCE(p_is_pinned, is_pinned),
         pinned_rank = CASE
           WHEN p_is_pinned IS TRUE THEN v_next_rank
           WHEN p_is_pinned IS FALSE THEN 0
           ELSE pinned_rank
         END,
         updated_at = now()
   WHERE id = p_post_id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'base_view_count', v_row.base_view_count,
    'is_pinned', v_row.is_pinned,
    'pinned_rank', v_row.pinned_rank,
    'view_count', COALESCE(v_row.view_count, 0) + COALESCE(v_row.base_view_count, 0)
  );
END;
$function$;