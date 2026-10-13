-- 达人口碑：分类保存改为 id 稳定的整组 upsert（根治「改分类清空已发笔记分类」）
-- + 审核列表加状态/关键词筛选 + 驳回必须填原因

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
  v_id uuid;
  v_result jsonb;
  v_keep uuid[] := ARRAY[]::uuid[];
  v_names text[] := ARRAY[]::text[];
  v_count integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  IF public.is_admin(auth.uid()) THEN
    v_root := p_root_manager_id;
  ELSE
    v_root := public.get_enterprise_root_manager_id(auth.uid());
  END IF;

  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限或未指定企业' USING ERRCODE = '42501';
  END IF;

  -- 先做整组校验：数量上限、名称长度、重名
  FOR v_cat IN SELECT * FROM jsonb_array_elements(COALESCE(p_categories, '[]'::jsonb))
  LOOP
    v_name := NULLIF(btrim(COALESCE(v_cat->>'name', '')), '');
    IF v_name IS NULL THEN
      CONTINUE;
    END IF;
    IF char_length(v_name) > 30 THEN
      RAISE EXCEPTION '分类名称最多 30 个字：%', v_name USING ERRCODE = 'P0001';
    END IF;
    IF v_name = ANY (v_names) THEN
      RAISE EXCEPTION '分类名称重复：%', v_name USING ERRCODE = 'P0001';
    END IF;
    v_names := array_append(v_names, v_name);
    v_count := v_count + 1;
  END LOOP;

  IF v_count > 20 THEN
    RAISE EXCEPTION '分类最多 20 个，当前 % 个', v_count USING ERRCODE = 'P0001';
  END IF;

  -- 同批次交换名称时，先把本企业现有行改成临时占位名，避开 UNIQUE(root_manager_id, name)
  UPDATE public.reputation_categories
     SET name = '__tmp_' || id::text
   WHERE root_manager_id = v_root;

  v_idx := 0;
  FOR v_cat IN SELECT * FROM jsonb_array_elements(COALESCE(p_categories, '[]'::jsonb))
  LOOP
    v_name := NULLIF(btrim(COALESCE(v_cat->>'name', '')), '');
    IF v_name IS NULL THEN
      CONTINUE;
    END IF;

    v_id := NULL;
    BEGIN
      v_id := NULLIF(btrim(COALESCE(v_cat->>'id', '')), '')::uuid;
    EXCEPTION WHEN others THEN
      v_id := NULL;
    END;

    IF v_id IS NOT NULL THEN
      -- 只允许改本企业的分类；id 不属于本企业时视为新增
      UPDATE public.reputation_categories
         SET name = v_name,
             sort_weight = COALESCE((v_cat->>'sort_weight')::int, v_idx)
       WHERE id = v_id AND root_manager_id = v_root;

      IF NOT FOUND THEN
        v_id := NULL;
      END IF;
    END IF;

    IF v_id IS NULL THEN
      INSERT INTO public.reputation_categories (root_manager_id, name, sort_weight)
      VALUES (v_root, v_name, COALESCE((v_cat->>'sort_weight')::int, v_idx))
      RETURNING id INTO v_id;
    END IF;

    v_keep := array_append(v_keep, v_id);
    v_idx := v_idx + 1;
  END LOOP;

  -- 只删除本次提交里没出现的旧分类（帖子的 category_id 由 ON DELETE SET NULL 置空，仅限被显式删除的分类）
  DELETE FROM public.reputation_categories
   WHERE root_manager_id = v_root
     AND NOT (id = ANY (v_keep));

  SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.sort_weight, c.name), '[]'::jsonb)
    INTO v_result
  FROM (
    SELECT id, name, sort_weight
    FROM public.reputation_categories
    WHERE root_manager_id = v_root
  ) c;

  RETURN jsonb_build_object('categories', COALESCE(v_result, '[]'::jsonb));
END;
$function$;

REVOKE ALL ON FUNCTION public.save_reputation_categories(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_reputation_categories(uuid, jsonb) TO authenticated;

-- 删除单个分类：明确告知会有多少篇笔记变成未分类
CREATE OR REPLACE FUNCTION public.count_reputation_category_posts(p_category_id uuid)
RETURNS integer
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT root_manager_id INTO v_root
  FROM public.reputation_categories WHERE id = p_category_id;

  IF v_root IS NULL THEN
    RETURN 0;
  END IF;

  IF NOT public.is_admin(auth.uid())
     AND public.get_enterprise_root_manager_id(auth.uid()) IS DISTINCT FROM v_root THEN
    RAISE EXCEPTION '无权查看该分类' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.reputation_posts
  WHERE category_id = p_category_id AND root_manager_id = v_root;

  RETURN COALESCE(v_count, 0);
END;
$function$;

REVOKE ALL ON FUNCTION public.count_reputation_category_posts(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.count_reputation_category_posts(uuid) TO authenticated;

-- 审核列表：加可选状态与关键词筛选（关键词覆盖标题、正文与作者昵称）
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

  SELECT COUNT(*) INTO v_total
  FROM public.reputation_posts p
  LEFT JOIN public.profiles pr ON pr.id = p.author_user_id
  WHERE p.root_manager_id = v_root
    AND (v_status IS NULL OR p.moderation_status = v_status)
    AND (
      v_search IS NULL
      OR p.title ILIKE '%' || v_search || '%'
      OR p.content ILIKE '%' || v_search || '%'
      OR COALESCE(pr.nickname, '') ILIKE '%' || v_search || '%'
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
      COALESCE(p.pinned_rank, 0) AS pinned_rank,
      COALESCE(p.base_view_count, 0) AS base_view_count,
      COALESCE(p.view_count, 0) + COALESCE(p.base_view_count, 0) AS view_count,
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
      AND (v_status IS NULL OR p.moderation_status = v_status)
      AND (
        v_search IS NULL
        OR p.title ILIKE '%' || v_search || '%'
        OR p.content ILIKE '%' || v_search || '%'
        OR COALESCE(pr.nickname, '') ILIKE '%' || v_search || '%'
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

REVOKE ALL ON FUNCTION public.list_enterprise_reputation_posts(uuid, integer, integer, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_enterprise_reputation_posts(uuid, integer, integer, text, text) TO authenticated;

-- 驳回必须写原因（2-300 字）；并支持带预期状态避免两人同时审同一篇
CREATE OR REPLACE FUNCTION public.moderate_reputation_post(
  p_post_id uuid,
  p_action text,
  p_note text DEFAULT NULL,
  p_expected_status text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_status text;
  v_current text;
  v_note text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT root_manager_id, moderation_status INTO v_root, v_current
  FROM public.reputation_posts WHERE id = p_post_id;

  IF v_root IS NULL THEN
    RAISE EXCEPTION '帖子不存在' USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.is_admin(auth.uid())
     AND public.get_enterprise_root_manager_id(auth.uid()) IS DISTINCT FROM v_root THEN
    RAISE EXCEPTION '无权操作该帖子' USING ERRCODE = '42501';
  END IF;

  IF p_expected_status IS NOT NULL AND v_current IS DISTINCT FROM p_expected_status THEN
    RAISE EXCEPTION '审核状态已变化，请刷新后重试' USING ERRCODE = 'P0001';
  END IF;

  v_note := NULLIF(btrim(COALESCE(p_note, '')), '');

  IF p_action = 'approve' THEN
    v_status := 'passed';
  ELSIF p_action = 'block' THEN
    v_status := 'blocked';
    IF v_note IS NULL OR char_length(v_note) < 2 THEN
      RAISE EXCEPTION '驳回必须填写原因（至少 2 个字）' USING ERRCODE = 'P0001';
    END IF;
    IF char_length(v_note) > 300 THEN
      RAISE EXCEPTION '驳回原因最多 300 个字' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    RAISE EXCEPTION '不支持的审核动作' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.reputation_posts
     SET moderation_status = v_status,
         review_note = v_note,
         updated_at = now()
   WHERE id = p_post_id;

  RETURN jsonb_build_object('id', p_post_id, 'moderation_status', v_status);
END;
$function$;

REVOKE ALL ON FUNCTION public.moderate_reputation_post(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.moderate_reputation_post(uuid, text, text, text) TO authenticated;

-- 审核筛选与列表用到的索引
CREATE INDEX IF NOT EXISTS idx_reputation_posts_root_status_created
  ON public.reputation_posts (root_manager_id, moderation_status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_reputation_posts_category
  ON public.reputation_posts (category_id);
