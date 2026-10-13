-- 修正：临时占位名必须满足 name <= 30 字的 CHECK 约束
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

  -- 同批次交换名称时先落到短临时名，避开 UNIQUE(root_manager_id, name)，同时满足 name <= 30 字
  WITH numbered AS (
    SELECT id, row_number() OVER (ORDER BY id) AS rn
    FROM public.reputation_categories
    WHERE root_manager_id = v_root
  )
  UPDATE public.reputation_categories c
     SET name = '~' || n.rn::text
    FROM numbered n
   WHERE c.id = n.id;

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
