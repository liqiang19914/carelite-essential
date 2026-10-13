-- 用户端内容列表：置顶真正生效（此前只按 sort_weight 排，商户在后台顶置的内容在客户侧没有体现），
-- 并补出 is_pinned 供列表页的顶部轮播只取置顶内容。
CREATE OR REPLACE FUNCTION public.get_public_content_module(p_manager_id uuid, p_limit integer DEFAULT 20, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_root uuid;
  v_name text;
  v_total integer;
  v_items jsonb;
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  v_offset integer := LEAST(GREATEST(COALESCE(p_offset, 0), 0), 10000);
BEGIN
  v_root := public.get_enterprise_root_manager_id(p_manager_id);

  IF v_root IS NULL
     OR NOT public.is_public_enterprise_content_root(v_root) THEN
    RETURN NULL;
  END IF;

  SELECT NULLIF(btrim(display_name), '') INTO v_name
  FROM public.manager_content_spaces
  WHERE root_manager_id = v_root;

  SELECT COUNT(*) INTO v_total
  FROM public.manager_content_items
  WHERE root_manager_id = v_root
    AND is_published = true
    AND moderation_status = 'passed';

  SELECT COALESCE(jsonb_agg(to_jsonb(item)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT
      i.id,
      i.content_type,
      i.title,
      i.cover_url,
      i.sort_weight,
      i.created_at,
      i.updated_at,
      i.like_count,
      COALESCE(i.is_pinned, false) AS is_pinned,
      COALESCE(i.view_count, 0) + COALESCE(i.base_view_count, 0) AS view_count,
      CASE
        WHEN i.content_type = 'album' THEN (
          SELECT COUNT(*)
          FROM public.manager_content_album_pages p
          WHERE p.content_id = i.id
        )
        ELSE 0
      END AS page_count
    FROM public.manager_content_items i
    WHERE i.root_manager_id = v_root
      AND i.is_published = true
      AND i.moderation_status = 'passed'
    ORDER BY
      COALESCE(i.is_pinned, false) DESC,
      COALESCE(i.pinned_rank, 0) DESC,
      i.sort_weight DESC,
      i.created_at DESC,
      i.id
    LIMIT v_limit OFFSET v_offset
  ) item;

  RETURN jsonb_build_object(
    'root_manager_id', v_root,
    'display_name', COALESCE(v_name, '健康学堂'),
    'total', v_total,
    'items', v_items
  );
END;
$function$;