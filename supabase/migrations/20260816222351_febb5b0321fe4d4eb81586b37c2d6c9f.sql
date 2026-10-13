-- 发帖入口：入口传 p_manager_id（服务端换算企业根），分类可选。
-- 参数顺序：带默认值的 p_category_id / p_images 必须排在无默认值参数之后。
CREATE OR REPLACE FUNCTION public.submit_reputation_post(
  p_manager_id uuid,
  p_title text,
  p_content text,
  p_category_id uuid DEFAULT NULL,
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

  v_root := public.get_enterprise_root_manager_id(p_manager_id);
  IF v_root IS NULL OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RAISE EXCEPTION '该商户尚未开放口碑' USING ERRCODE = 'P0002';
  END IF;

  IF p_category_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.reputation_categories
      WHERE id = p_category_id AND root_manager_id = v_root
    ) THEN
      RAISE EXCEPTION '所选分类不存在' USING ERRCODE = 'P0002';
    END IF;
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

REVOKE ALL ON FUNCTION public.submit_reputation_post(uuid, text, text, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_reputation_post(uuid, text, text, uuid, jsonb) TO authenticated;