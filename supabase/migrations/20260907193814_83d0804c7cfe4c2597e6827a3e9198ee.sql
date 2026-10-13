-- 457：查询健管师 6 位短码（桌面预览/门店咨询拼短码链接用）
-- managers 表 SELECT 被 RLS 限定为本人才可见，公开拼链接需要 SECURITY DEFINER 独立入口。

CREATE OR REPLACE FUNCTION public.get_manager_short_code(p_manager_id uuid)
RETURNS text
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT NULLIF(btrim(short_code), '')
  FROM public.managers
  WHERE id = p_manager_id;
$function$;
GRANT EXECUTE ON FUNCTION public.get_manager_short_code(uuid) TO anon, authenticated;