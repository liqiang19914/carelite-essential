-- 课程详情四 Tab：相关商品字段 + 点赞/学习/评论三张表 + 互动 RPC + 公开课程接口扩展

ALTER TABLE public.manager_courses
  ADD COLUMN IF NOT EXISTS related_product_ids uuid[];

COMMENT ON COLUMN public.manager_courses.related_product_ids IS
  '课程相关商品（商品 id 数组），课程详情「相关商品」Tab 展示';

CREATE TABLE IF NOT EXISTS public.course_likes (
  course_id uuid NOT NULL REFERENCES public.manager_courses(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (course_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.course_studies (
  course_id uuid NOT NULL REFERENCES public.manager_courses(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (course_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.course_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  course_id uuid NOT NULL REFERENCES public.manager_courses(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  content text NOT NULL CHECK (char_length(btrim(content)) BETWEEN 1 AND 500),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS course_comments_course_idx
  ON public.course_comments (course_id, created_at DESC, id);

-- 点赞开关：切换当前用户对课程的点赞，返回最新状态与总数
CREATE OR REPLACE FUNCTION public.toggle_course_like(p_course_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_liked boolean := false;
  v_like_count integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再点赞' USING ERRCODE = '28000';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.manager_courses WHERE id = p_course_id) THEN
    RAISE EXCEPTION '课程不存在' USING ERRCODE = 'P0002';
  END IF;

  IF EXISTS (SELECT 1 FROM public.course_likes WHERE course_id = p_course_id AND user_id = v_uid) THEN
    DELETE FROM public.course_likes WHERE course_id = p_course_id AND user_id = v_uid;
    UPDATE public.manager_courses SET like_count = GREATEST(like_count - 1, 0) WHERE id = p_course_id;
    v_liked := false;
  ELSE
    INSERT INTO public.course_likes (course_id, user_id) VALUES (p_course_id, v_uid);
    UPDATE public.manager_courses SET like_count = like_count + 1 WHERE id = p_course_id;
    v_liked := true;
  END IF;

  SELECT like_count INTO v_like_count FROM public.manager_courses WHERE id = p_course_id;
  RETURN jsonb_build_object('liked', v_liked, 'like_count', COALESCE(v_like_count, 0));
END;
$function$;

REVOKE ALL ON FUNCTION public.toggle_course_like(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.toggle_course_like(uuid) TO authenticated;

-- 记录学习：每个用户对每门课程只计一次，学习人数 +1
CREATE OR REPLACE FUNCTION public.record_course_study(p_course_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_inserted boolean := false;
  v_study_count integer;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('recorded', false, 'study_count', 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.manager_courses WHERE id = p_course_id) THEN
    RETURN jsonb_build_object('recorded', false, 'study_count', 0);
  END IF;

  INSERT INTO public.course_studies (course_id, user_id) VALUES (p_course_id, v_uid)
  ON CONFLICT (course_id, user_id) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  IF v_inserted THEN
    UPDATE public.manager_courses SET study_count = study_count + 1 WHERE id = p_course_id;
  END IF;

  SELECT study_count INTO v_study_count FROM public.manager_courses WHERE id = p_course_id;
  RETURN jsonb_build_object('recorded', v_inserted, 'study_count', COALESCE(v_study_count, 0));
END;
$function$;

REVOKE ALL ON FUNCTION public.record_course_study(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_course_study(uuid) TO authenticated;

-- 发评论
CREATE OR REPLACE FUNCTION public.add_course_comment(p_course_id uuid, p_content text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_content text := NULLIF(btrim(COALESCE(p_content, '')), '');
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录后再评论' USING ERRCODE = '28000';
  END IF;
  IF v_content IS NULL OR char_length(v_content) > 500 THEN
    RAISE EXCEPTION '评论内容需为 1-500 字' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.manager_courses WHERE id = p_course_id) THEN
    RAISE EXCEPTION '课程不存在' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.course_comments (course_id, user_id, content)
  VALUES (p_course_id, v_uid, v_content)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'course_id', p_course_id, 'created_at', now());
END;
$function$;

REVOKE ALL ON FUNCTION public.add_course_comment(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_course_comment(uuid, text) TO authenticated;

-- 评论列表（匿名可读）
CREATE OR REPLACE FUNCTION public.list_course_comments(p_course_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'id', cc.id,
        'content', cc.content,
        'nickname', COALESCE(p.nickname, '用户'),
        'avatar_url', p.avatar_url,
        'created_at', cc.created_at
      )
      ORDER BY cc.created_at DESC
    )
    FROM public.course_comments cc
    LEFT JOIN public.profiles p ON p.id = cc.user_id
    WHERE cc.course_id = p_course_id
  ), '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_course_comments(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_course_comments(uuid) TO anon, authenticated;

-- 公开课程详情：扩展点赞数/学习人数/相关商品/我的点赞学习状态
CREATE OR REPLACE FUNCTION public.get_public_manager_course(
  p_manager_id uuid,
  p_course_id uuid
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $function$
DECLARE
  v_course manager_courses%ROWTYPE;
  v_chapters JSON;
  v_is_bound BOOLEAN := false;
  v_uid UUID;
  v_like_count INTEGER := 0;
  v_study_count INTEGER := 0;
  v_my_liked BOOLEAN := false;
  v_my_studied BOOLEAN := false;
  v_products JSON;
BEGIN
  IF p_manager_id IS NULL OR p_course_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_uid := auth.uid();

  SELECT * INTO v_course
  FROM manager_courses
  WHERE id = p_course_id
    AND manager_id = p_manager_id
    AND is_published = true
    AND review_status = 'approved';

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_course.visibility = 'clients_only' THEN
    IF v_uid IS NULL THEN
      RETURN json_build_object(
        'gated', true,
        'reason', 'unauthenticated',
        'manager_id', v_course.manager_id
      );
    END IF;

    SELECT EXISTS (
      SELECT 1 FROM client_relations
      WHERE client_id = v_uid
        AND manager_id = p_manager_id
        AND status = 'active'
    ) INTO v_is_bound;

    IF NOT v_is_bound AND NOT public.is_admin(v_uid) THEN
      RETURN json_build_object(
        'gated', true,
        'reason', 'not_bound',
        'manager_id', v_course.manager_id
      );
    END IF;
  END IF;

  SELECT json_agg(
    json_build_object(
      'id', mcc.id,
      'sort_order', mcc.sort_order,
      'title', mcc.title,
      'intro', mcc.intro,
      'duration_seconds', mcc.duration_seconds,
      'video_url', mcc.video_url,
      'video_source', mcc.video_source,
      'cover_url', mcc.cover_url,
      'is_free_preview', mcc.is_free_preview,
      'is_active', mcc.is_active
    )
    ORDER BY mcc.sort_order ASC, mcc.created_at ASC
  ) INTO v_chapters
  FROM manager_course_chapters mcc
  WHERE mcc.course_id = v_course.id
    AND mcc.is_active = true;

  v_like_count := COALESCE(v_course.like_count, 0);
  v_study_count := COALESCE(v_course.study_count, 0);
  IF v_uid IS NOT NULL THEN
    SELECT EXISTS (SELECT 1 FROM course_likes WHERE course_id = p_course_id AND user_id = v_uid) INTO v_my_liked;
    SELECT EXISTS (SELECT 1 FROM course_studies WHERE course_id = p_course_id AND user_id = v_uid) INTO v_my_studied;
  END IF;

  IF v_course.related_product_ids IS NOT NULL AND array_length(v_course.related_product_ids, 1) > 0 THEN
    SELECT json_agg(
      json_build_object(
        'id', p.id,
        'title', p.title,
        'cover_image_url', p.cover_image_url,
        'price_cents', sku.price_cents
      )
    ) INTO v_products
    FROM products p
    LEFT JOIN product_skus sku
      ON sku.product_id = p.id AND sku.is_default = true AND sku.is_active = true
    WHERE p.id = ANY (v_course.related_product_ids)
      AND p.status = 'active';
  END IF;

  RETURN json_build_object(
    'id', v_course.id,
    'manager_id', v_course.manager_id,
    'title', v_course.title,
    'cover_image_url', v_course.cover_image_url,
    'description', v_course.description,
    'duration_minutes', v_course.duration_minutes,
    'visibility', v_course.visibility,
    'like_count', v_like_count,
    'study_count', v_study_count,
    'my_liked', v_my_liked,
    'my_studied', v_my_studied,
    'related_products', COALESCE(v_products, '[]'::JSON),
    'chapters', COALESCE(v_chapters, '[]'::JSON),
    'created_at', v_course.created_at
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.get_public_manager_course(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_manager_course(uuid, uuid) TO anon, authenticated;

-- 三张互动表：匿名与前端一律不直接碰表，全部经 RPC
ALTER TABLE public.course_likes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_studies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_comments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.course_likes FROM anon, authenticated;
REVOKE ALL ON public.course_studies FROM anon, authenticated;
REVOKE ALL ON public.course_comments FROM anon, authenticated;