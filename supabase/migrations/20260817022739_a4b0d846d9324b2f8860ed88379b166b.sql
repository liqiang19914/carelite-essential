-- 内容点赞：计数列 + 点赞表 + 切换 RPC + 公开详情返回点赞态
ALTER TABLE public.manager_content_items
  ADD COLUMN IF NOT EXISTS like_count integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.manager_content_items.like_count IS '客户点赞数（由 toggle_content_like 维护）';

CREATE TABLE IF NOT EXISTS public.manager_content_likes (
  content_id uuid NOT NULL REFERENCES public.manager_content_items(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (content_id, user_id)
);

ALTER TABLE public.manager_content_likes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.manager_content_likes FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.toggle_content_like(p_content_id uuid)
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
  IF NOT EXISTS (SELECT 1 FROM public.manager_content_items WHERE id = p_content_id) THEN
    RAISE EXCEPTION '内容不存在' USING ERRCODE = 'P0002';
  END IF;

  IF EXISTS (SELECT 1 FROM public.manager_content_likes WHERE content_id = p_content_id AND user_id = v_uid) THEN
    DELETE FROM public.manager_content_likes WHERE content_id = p_content_id AND user_id = v_uid;
    UPDATE public.manager_content_items SET like_count = GREATEST(like_count - 1, 0) WHERE id = p_content_id;
    v_liked := false;
  ELSE
    INSERT INTO public.manager_content_likes (content_id, user_id) VALUES (p_content_id, v_uid);
    UPDATE public.manager_content_items SET like_count = like_count + 1 WHERE id = p_content_id;
    v_liked := true;
  END IF;

  SELECT like_count INTO v_like_count FROM public.manager_content_items WHERE id = p_content_id;
  RETURN jsonb_build_object('liked', v_liked, 'like_count', COALESCE(v_like_count, 0));
END;
$function$;

REVOKE ALL ON FUNCTION public.toggle_content_like(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.toggle_content_like(uuid) TO authenticated;

-- 公开详情返回点赞数与当前用户点赞态
CREATE OR REPLACE FUNCTION public.get_public_content_item(
  p_manager_id uuid,
  p_content_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_name text;
  v_item jsonb;
  v_pages jsonb := '[]'::jsonb;
  v_type text;
  v_like_count integer;
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
    jsonb_build_object(
      'id', id,
      'content_type', content_type,
      'title', title,
      'cover_url', cover_url,
      'article_doc', article_doc,
      'created_at', created_at,
      'updated_at', updated_at
    )
    INTO v_type, v_like_count, v_item
  FROM public.manager_content_items
  WHERE id = p_content_id
    AND root_manager_id = v_root
    AND is_published = true
    AND moderation_status = 'passed';

  IF v_item IS NULL THEN
    RETURN NULL;
  END IF;

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
    'my_liked', COALESCE(v_my_liked, false)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_content_item(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_content_item(uuid, uuid)
  TO anon, authenticated;