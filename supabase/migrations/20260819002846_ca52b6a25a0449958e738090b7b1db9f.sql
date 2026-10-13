-- 健管师页装修按商户隔离（feature 185）
-- 现状缺陷：get_published_shop_config(p_manager_id) 服务端 get_enterprise_root_manager_id(p_manager_id)
-- 反查"这个健管师属于哪家企业"。平台的健管师不属于任何企业，反查落空，
-- 平台名片页读装修会落到别的企业（A 一改 B 就跟着变）。
-- 修法：新增 get_published_shop_config_for_root(p_root_manager_id)，按"你现在站在哪家店的壳里"
-- 直接传企业根。不再反查健管师。商户非法（不是公开内容根）返回空。
-- 老函数保留给内容中心/学堂/商城用（它们本身就是"在这家店里读"），不受影响。

CREATE OR REPLACE FUNCTION public.get_published_shop_config_for_root(p_root_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row public.merchant_shop_configs%ROWTYPE;
BEGIN
  -- 商户非法（不存在、或不是可被公开访问的内容根）一律返回空：前端回落默认模板，
  -- 绝不把别家企业的装修吐出来。
  IF p_root_manager_id IS NULL
     OR NOT public.is_public_enterprise_content_root(p_root_manager_id) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_shop_configs
  WHERE root_manager_id = p_root_manager_id;

  -- 一行都没有 / 从没发布过：也返回空，前端回落默认模板
  IF NOT FOUND OR v_row.published_at IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'root_manager_id', p_root_manager_id,
    'published_at', v_row.published_at,
    'pages', public.validate_shop_pages(COALESCE(v_row.published_pages, '{}'::jsonb))
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_published_shop_config_for_root(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_published_shop_config_for_root(uuid) TO anon, authenticated;