-- 商户的可读入口标识：未填时用现有短码，所以不加唯一约束
-- （默认 fallback 的短码本来就唯一，只有人工填的 brand_slug 需要避免冲突，交给后台写入时校验）
ALTER TABLE public.managers ADD COLUMN IF NOT EXISTS brand_slug text;

-- 按入口标识认商户：优先读后台填的可读标识，否则用短码。
-- 只认启用中的管理师，被停用的商户路径立即失效。
CREATE OR REPLACE FUNCTION public.resolve_manager_by_slug(p_slug text)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT m.id
  FROM public.managers m
  JOIN public.profiles p ON p.id = m.id
  WHERE (m.brand_slug = p_slug OR (m.brand_slug IS NULL AND m.short_code = p_slug))
    AND p.role::text = 'manager'
    AND COALESCE(p.is_disabled, false) = false
  LIMIT 1;
$$;

REVOKE EXECUTE ON FUNCTION public.resolve_manager_by_slug(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.resolve_manager_by_slug(text) TO anon, authenticated, service_role;