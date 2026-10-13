CREATE OR REPLACE FUNCTION public.admin_set_manager_brand_slug(p_manager_id uuid, p_slug text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_slug text := lower(nullif(btrim(COALESCE(p_slug, '')), ''));
BEGIN
  IF NOT public.is_admin((SELECT auth.uid())) THEN
    RAISE EXCEPTION '只有平台管理员可以设置商户入口标识' USING ERRCODE = '42501';
  END IF;
  IF v_slug IS NOT NULL AND v_slug !~ '^[a-z0-9][a-z0-9-]{1,40}$' THEN
    RAISE EXCEPTION '标识只能用小写字母、数字和中划线，至少 2 个字符' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.managers WHERE id = p_manager_id) THEN
    RAISE EXCEPTION '商户不存在' USING ERRCODE = '22023';
  END IF;
  IF v_slug IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.managers
    WHERE brand_slug = v_slug AND id <> p_manager_id
  ) THEN
    RAISE EXCEPTION '这个标识已被另一家商户使用' USING ERRCODE = '23505';
  END IF;

  UPDATE public.managers SET brand_slug = v_slug WHERE id = p_manager_id;

  RETURN json_build_object(
    'success', true,
    'brand_slug', v_slug,
    'short_code', (SELECT m.short_code FROM public.managers m WHERE m.id = p_manager_id)
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_set_manager_brand_slug(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_set_manager_brand_slug(uuid, text) TO authenticated, service_role;