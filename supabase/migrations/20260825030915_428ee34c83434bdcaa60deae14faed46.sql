-- 推广码落地页信息：公开读取（slug 本身公开），扫码落地页用它决定跳转目标
CREATE OR REPLACE FUNCTION public.get_promotion_landing(p_short_code text)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT jsonb_build_object(
    'valid', EXISTS (
      SELECT 1 FROM public.promotion_codes pc
      WHERE pc.short_code = btrim(COALESCE(p_short_code, '')) AND pc.is_active = true
    ),
    'slug', (
      SELECT COALESCE(m.brand_slug, m.short_code)
      FROM public.promotion_codes pc
      JOIN public.managers m ON m.id = pc.enterprise_root_id
      WHERE pc.short_code = btrim(COALESCE(p_short_code, '')) AND pc.is_active = true
      LIMIT 1
    )
  );
$function$;