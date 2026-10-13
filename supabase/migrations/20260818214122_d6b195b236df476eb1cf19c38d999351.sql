-- 审查修复（达人口碑）
-- 1) 分类保存严格校验提交的 id：非法 UUID / 重复 / 不属于本企业一律报错回滚，
--    不再静默当成"新增"——否则旧分类会被当作未提交而删除，已发笔记的分类被 ON DELETE SET NULL 清空。
-- 2) 交换名称用的临时占位名改成带随机段的前缀，且与现有名称、本次提交的终名都做过对撞检查
--    （"~1" 本身也是合法分类名，固定占用会让正常保存失败）。
-- 3) 审核改成带状态条件的原子更新：两人同时审同一篇时后提交者收到"状态已变化"，不再静默覆盖。
-- 4) 审核列表关键词转义 \ % _，避免搜 "%" 命中全部笔记。

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
  v_raw_id text;
  v_id uuid;
  v_weight integer;
  v_result jsonb;
  v_keep uuid[] := ARRAY[]::uuid[];
  v_ids uuid[] := ARRAY[]::uuid[];
  v_names text[] := ARRAY[]::text[];
  v_count integer := 0;
  v_owned integer;
  v_prefix text;
  v_try integer := 0;
  v_clash integer;
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

  -- 整组校验：所有可能导致旧分类被删的问题都必须挡在任何改动之前
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

    v_raw_id := NULLIF(btrim(COALESCE(v_cat->>'id', '')), '');
    IF v_raw_id IS NOT NULL THEN
      IF v_raw_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        RAISE EXCEPTION '分类数据已过期，请刷新页面后重新保存' USING ERRCODE = 'P0001';
      END IF;
      v_id := v_raw_id::uuid;
      IF v_id = ANY (v_ids) THEN
        RAISE EXCEPTION '同一个分类被提交了两次，请刷新页面后重新保存' USING ERRCODE = 'P0001';
      END IF;
      SELECT count(*) INTO v_owned
      FROM public.reputation_categories
      WHERE id = v_id AND root_manager_id = v_root;
      IF v_owned = 0 THEN
        RAISE EXCEPTION '有分类已被删除或不属于当前企业，请刷新页面后重新保存' USING ERRCODE = 'P0001';
      END IF;
      v_ids := array_append(v_ids, v_id);
    END IF;
  END LOOP;

  IF v_count > 20 THEN
    RAISE EXCEPTION '分类最多 20 个，当前 % 个', v_count USING ERRCODE = 'P0001';
  END IF;

  -- 临时占位名：带随机段，且确认既不撞库里现有名称也不撞本次要写入的终名
  LOOP
    v_try := v_try + 1;
    v_prefix := '~' || substr(md5(random()::text || clock_timestamp()::text), 1, 8) || '-';

    SELECT count(*) INTO v_clash
    FROM public.reputation_categories
    WHERE root_manager_id = v_root AND position(v_prefix in name) = 1;

    IF v_clash = 0 THEN
      SELECT count(*) INTO v_clash
      FROM unnest(v_names) AS n(name)
      WHERE position(v_prefix in n.name) = 1;
    END IF;

    EXIT WHEN v_clash = 0;

    IF v_try >= 10 THEN
      RAISE EXCEPTION '分类保存冲突，请稍后重试' USING ERRCODE = 'P0001';
    END IF;
  END LOOP;

  WITH numbered AS (
    SELECT id, row_number() OVER (ORDER BY id) AS rn
    FROM public.reputation_categories
    WHERE root_manager_id = v_root
  )
  UPDATE public.reputation_categories c
     SET name = v_prefix || n.rn::text
    FROM numbered n
   WHERE c.id = n.id;

  v_idx := 0;
  FOR v_cat IN SELECT * FROM jsonb_array_elements(COALESCE(p_categories, '[]'::jsonb))
  LOOP
    v_name := NULLIF(btrim(COALESCE(v_cat->>'name', '')), '');
    IF v_name IS NULL THEN
      CONTINUE;
    END IF;

    v_raw_id := NULLIF(btrim(COALESCE(v_cat->>'id', '')), '');
    -- 排序值来自不透明 JSON，非整数一律用当前次序，避免抛出非中文的类型转换错误
    v_weight := CASE
      WHEN COALESCE(v_cat->>'sort_weight', '') ~ '^-?[0-9]{1,9}$'
        THEN (v_cat->>'sort_weight')::int
      ELSE v_idx
    END;

    IF v_raw_id IS NOT NULL THEN
      v_id := v_raw_id::uuid;
      UPDATE public.reputation_categories
         SET name = v_name,
             sort_weight = v_weight
       WHERE id = v_id AND root_manager_id = v_root;

      IF NOT FOUND THEN
        -- 归属已在校验阶段确认过，这里落空只可能是并发删除
        RAISE EXCEPTION '有分类刚刚被删除，请刷新页面后重新保存' USING ERRCODE = 'P0001';
      END IF;
    ELSE
      INSERT INTO public.reputation_categories (root_manager_id, name, sort_weight)
      VALUES (v_root, v_name, v_weight)
      RETURNING id INTO v_id;
    END IF;

    v_keep := array_append(v_keep, v_id);
    v_idx := v_idx + 1;
  END LOOP;

  -- 只删除本次提交里没出现的旧分类（笔记的 category_id 由 ON DELETE SET NULL 置空）
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

  -- 状态条件写进 UPDATE 本身：上面的预检查与写入之间仍有窗口，
  -- 两人同时审同一篇时必须让后提交者失败，而不是覆盖前一个人的结论。
  UPDATE public.reputation_posts
     SET moderation_status = v_status,
         review_note = v_note,
         updated_at = now()
   WHERE id = p_post_id
     AND (p_expected_status IS NULL OR moderation_status = p_expected_status);

  IF NOT FOUND THEN
    RAISE EXCEPTION '审核状态已变化，请刷新后重试' USING ERRCODE = 'P0001';
  END IF;

  RETURN jsonb_build_object('id', p_post_id, 'moderation_status', v_status);
END;
$function$;

REVOKE ALL ON FUNCTION public.moderate_reputation_post(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.moderate_reputation_post(uuid, text, text, text) TO authenticated;

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

  -- 商户直接输入的关键词：% 与 _ 必须转义，否则搜一个 % 就命中全部笔记
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
        v_like IS NULL
        OR p.title ILIKE v_like ESCAPE '\'
        OR p.content ILIKE v_like ESCAPE '\'
        OR COALESCE(pr.nickname, '') ILIKE v_like ESCAPE '\'
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