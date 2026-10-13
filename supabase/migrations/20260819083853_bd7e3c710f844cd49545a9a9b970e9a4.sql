-- ============================================================
-- 口碑展示位（初始阅读量/置顶）并发保护
-- 新增两个可选期望值参数；带上时 UPDATE 条件要求库内现值一致，
-- 不一致报中文并发冲突，后保存者不再静默覆盖先保存者。
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_reputation_post_display(
  p_post_id uuid,
  p_base_view_count integer DEFAULT NULL,
  p_is_pinned boolean DEFAULT NULL,
  p_expected_base_view_count integer DEFAULT NULL,
  p_expected_is_pinned boolean DEFAULT NULL
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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT root_manager_id, base_view_count, is_pinned
    INTO v_root, v_cur_base, v_cur_pinned
  FROM public.reputation_posts WHERE id = p_post_id
  FOR UPDATE;

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

  -- 带了期望值就必须与库内现值一致，否则说明有人先改过了
  IF p_expected_base_view_count IS NOT NULL
     AND v_cur_base IS DISTINCT FROM p_expected_base_view_count THEN
    RAISE EXCEPTION '这条笔记刚被同事改过，请刷新后重试' USING ERRCODE = 'P0002';
  END IF;
  IF p_expected_is_pinned IS NOT NULL
     AND v_cur_pinned IS DISTINCT FROM p_expected_is_pinned THEN
    RAISE EXCEPTION '这条笔记刚被同事改过，请刷新后重试' USING ERRCODE = 'P0002';
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

  IF NOT FOUND THEN
    RAISE EXCEPTION '笔记不存在' USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'base_view_count', v_row.base_view_count,
    'is_pinned', v_row.is_pinned,
    'pinned_rank', v_row.pinned_rank,
    'view_count', COALESCE(v_row.view_count, 0) + COALESCE(v_row.base_view_count, 0)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.set_reputation_post_display(uuid, integer, boolean, integer, boolean) TO authenticated;