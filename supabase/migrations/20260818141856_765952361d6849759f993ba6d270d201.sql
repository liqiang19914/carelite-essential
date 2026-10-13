-- 补上企业课程的可跳转 manager id（企业超管），列表页才能拼出课程详情路径
CREATE OR REPLACE FUNCTION public.list_my_favorites(
  p_brand_manager_id uuid DEFAULT NULL,
  p_group text DEFAULT NULL,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_zero uuid := '00000000-0000-0000-0000-000000000000';
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
  v_group text := NULLIF(btrim(COALESCE(p_group, '')), '');
  v_total integer := 0;
  v_items jsonb := '[]'::jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('total', 0, 'items', '[]'::jsonb);
  END IF;
  IF v_group IS NOT NULL AND v_group NOT IN ('product','content','course') THEN
    RAISE EXCEPTION '收藏分类参数不正确';
  END IF;

  v_root := public._favorite_brand_scope(p_brand_manager_id);

  SELECT COUNT(*) INTO v_total
  FROM public.user_favorites f
  WHERE f.user_id = v_uid
    AND COALESCE(f.brand_root_manager_id, v_zero) = COALESCE(v_root, v_zero)
    AND (
      v_group IS NULL
      OR (v_group = 'product' AND f.target_type = 'product')
      OR (v_group = 'content' AND f.target_type = 'content')
      OR (v_group = 'course' AND f.target_type IN ('manager_course','enterprise_course'))
    );

  SELECT COALESCE(jsonb_agg(t.item ORDER BY t.created_at DESC, t.fid DESC), '[]'::jsonb)
    INTO v_items
  FROM (
    SELECT
      f.id AS fid,
      f.created_at,
      jsonb_build_object(
        'id', f.id,
        'target_type', f.target_type,
        'target_id', f.target_id,
        'created_at', f.created_at,
        'is_valid', public._favorite_target_valid(v_uid, v_root, f.target_type, f.target_id),
        'title', COALESCE(p.title, ci.title, mc.title, ec.title),
        'cover_url', COALESCE(
          NULLIF(p.cover_image_url, ''),
          p.cover_images->>0,
          NULLIF(ci.cover_url, ''),
          NULLIF(mc.cover_image_url, ''),
          NULLIF(ec.cover_image_url, '')
        ),
        'subtitle', COALESCE(
          NULLIF(p.subtitle, ''),
          NULLIF(mc.description, ''),
          NULLIF(ec.description, '')
        ),
        'content_type', ci.content_type,
        'sale_mode', COALESCE(p.sale_mode, 'cash'),
        'price_cents', sku.price_cents,
        'points_price', sku.points_price,
        'course_manager_id', COALESCE(mc.manager_id, ent.owner_profile_id)
      ) AS item
    FROM (
      SELECT uf.id, uf.created_at, uf.target_type, uf.target_id
      FROM public.user_favorites uf
      WHERE uf.user_id = v_uid
        AND COALESCE(uf.brand_root_manager_id, v_zero) = COALESCE(v_root, v_zero)
        AND (
          v_group IS NULL
          OR (v_group = 'product' AND uf.target_type = 'product')
          OR (v_group = 'content' AND uf.target_type = 'content')
          OR (v_group = 'course' AND uf.target_type IN ('manager_course','enterprise_course'))
        )
      ORDER BY uf.created_at DESC, uf.id DESC
      LIMIT v_limit OFFSET v_offset
    ) f
    LEFT JOIN public.products p
      ON f.target_type = 'product' AND p.id = f.target_id
    LEFT JOIN LATERAL (
      SELECT s.price_cents, s.points_price
      FROM public.product_skus s
      WHERE p.id IS NOT NULL AND s.product_id = p.id
      ORDER BY s.is_default DESC, s.created_at ASC
      LIMIT 1
    ) sku ON TRUE
    LEFT JOIN public.manager_content_items ci
      ON f.target_type = 'content' AND ci.id = f.target_id
    LEFT JOIN public.manager_courses mc
      ON f.target_type = 'manager_course' AND mc.id = f.target_id
    LEFT JOIN public.enterprise_courses ec
      ON f.target_type = 'enterprise_course' AND ec.id = f.target_id
    LEFT JOIN public.enterprises ent
      ON f.target_type = 'enterprise_course' AND ent.id = ec.enterprise_id
  ) t;

  RETURN jsonb_build_object(
    'total', v_total,
    'items', v_items,
    'brand_root_manager_id', v_root
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_my_favorites(uuid, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_my_favorites(uuid, text, integer, integer) TO authenticated;