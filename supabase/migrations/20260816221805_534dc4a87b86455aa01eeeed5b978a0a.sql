-- ============================================================================
-- 达人口碑：商户后台管理 + 平台审核（authenticated manager/admin）
-- ============================================================================

-- 企业口碑帖子列表（含作者昵称与分类名，任意状态），供商户后台与平台审核
CREATE OR REPLACE FUNCTION public.list_enterprise_reputation_posts(
  p_root_manager_id uuid DEFAULT NULL,
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
  v_posts jsonb;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  v_offset integer := LEAST(GREATEST(COALESCE(p_offset, 0), 0), 10000);
BEGIN
  IF public.is_admin(auth.uid()) THEN
    v_root := p_root_manager_id;
  ELSE
    v_root := public.get_enterprise_root_manager_id(auth.uid());
  END IF;

  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限或未指定企业' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM public.reputation_posts
  WHERE root_manager_id = v_root;

  SELECT COALESCE(jsonb_agg(to_jsonb(item) ORDER BY item.created_at DESC, item.id), '[]'::jsonb)
    INTO v_posts
  FROM (
    SELECT
      p.id,
      p.category_id,
      c.name AS category_name,
      p.title,
      p.content,
      p.like_count,
      p.comment_count,
      p.moderation_status,
      p.review_note,
      p.created_at,
      pr.nickname AS author_name,
      COALESCE((
        SELECT jsonb_agg(jsonb_build_object('image_url', i.image_url, 'is_before', i.is_before) ORDER BY i.sort_order)
        FROM public.reputation_post_images i
        WHERE i.post_id = p.id
      ), '[]'::jsonb) AS images
    FROM public.reputation_posts p
    LEFT JOIN public.reputation_categories c ON c.id = p.category_id
    LEFT JOIN public.profiles pr ON pr.id = p.author_user_id
    WHERE p.root_manager_id = v_root
    ORDER BY p.created_at DESC, p.id
    LIMIT v_limit OFFSET v_offset
  ) item;

  RETURN jsonb_build_object('total', v_total, 'posts', v_posts);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_reputation_posts(uuid, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_enterprise_reputation_posts(uuid, integer, integer) TO authenticated;

-- 审核/处置：approve 放行公开，block 下架；admin 或帖子所属企业成员可操作
CREATE OR REPLACE FUNCTION public.moderate_reputation_post(
  p_post_id uuid,
  p_action text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_status text;
BEGIN
  SELECT root_manager_id INTO v_root
  FROM public.reputation_posts WHERE id = p_post_id;

  IF v_root IS NULL THEN
    RAISE EXCEPTION '帖子不存在' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.is_admin(auth.uid())
     AND public.get_enterprise_root_manager_id(auth.uid()) IS DISTINCT FROM v_root THEN
    RAISE EXCEPTION '无权操作该帖子' USING ERRCODE = '42501';
  END IF;

  IF p_action = 'approve' THEN
    v_status := 'passed';
  ELSIF p_action = 'block' THEN
    v_status := 'blocked';
  ELSE
    RAISE EXCEPTION '不支持的审核动作' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.reputation_posts
     SET moderation_status = v_status,
         review_note = NULLIF(btrim(COALESCE(p_note, '')), ''),
         updated_at = now()
   WHERE id = p_post_id;

  RETURN jsonb_build_object('id', p_post_id, 'moderation_status', v_status);
END;
$function$;

REVOKE ALL ON FUNCTION public.moderate_reputation_post(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.moderate_reputation_post(uuid, text, text) TO authenticated;

-- 删除：作者 / 帖子所属企业成员 / 平台管理员可删
CREATE OR REPLACE FUNCTION public.delete_reputation_post(p_post_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_author uuid;
BEGIN
  SELECT root_manager_id, author_user_id INTO v_root, v_author
  FROM public.reputation_posts WHERE id = p_post_id;

  IF v_root IS NULL THEN
    RETURN false;
  END IF;

  IF auth.uid() IS DISTINCT FROM v_author
     AND NOT public.is_admin(auth.uid())
     AND public.get_enterprise_root_manager_id(auth.uid()) IS DISTINCT FROM v_root THEN
    RAISE EXCEPTION '无权删除该帖子' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.reputation_posts WHERE id = p_post_id;
  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_reputation_post(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_reputation_post(uuid) TO authenticated;

-- 分类全量替换（商户自己企业；admin 可传 p_root_manager_id）
CREATE OR REPLACE FUNCTION public.save_reputation_categories(
  p_root_manager_id uuid DEFAULT NULL,
  p_categories jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_cat jsonb;
  v_idx integer := 0;
  v_name text;
BEGIN
  IF public.is_admin(auth.uid()) THEN
    v_root := p_root_manager_id;
  ELSE
    v_root := public.get_enterprise_root_manager_id(auth.uid());
  END IF;

  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限或未指定企业' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.reputation_categories WHERE root_manager_id = v_root;

  FOR v_cat IN SELECT * FROM jsonb_array_elements(COALESCE(p_categories, '[]'::jsonb))
  LOOP
    v_name := NULLIF(btrim(COALESCE(v_cat->>'name', '')), '');
    IF v_name IS NULL THEN
      CONTINUE;
    END IF;
    INSERT INTO public.reputation_categories (root_manager_id, name, sort_weight)
    VALUES (v_root, v_name, COALESCE((v_cat->>'sort_weight')::int, v_idx));
    v_idx := v_idx + 1;
  END LOOP;

  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.sort_weight, c.name), '[]'::jsonb)
    INTO v_cat
  FROM (
    SELECT id, name, sort_weight
    FROM public.reputation_categories
    WHERE root_manager_id = v_root
  ) c;

  RETURN jsonb_build_object('categories', COALESCE(v_cat, '[]'::jsonb));
END;
$function$;

REVOKE ALL ON FUNCTION public.save_reputation_categories(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_reputation_categories(uuid, jsonb) TO authenticated;