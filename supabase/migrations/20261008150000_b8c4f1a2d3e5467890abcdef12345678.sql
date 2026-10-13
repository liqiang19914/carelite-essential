-- ============================================================================
-- W3 增补：官网自定义域名入口（purpose='site'）
--   * manager_domains.purpose / site_id 已在 W1 迁移加好，这里接通 RPC
--   * add_my_domain 增加 p_purpose（默认 shop，旧调用方零改动）
--   * purpose='site' 时自动把域名挂到该商户的 merchant_sites 上
--   * 网关按 Host 分流到 site-serve 属 M2 运维项，M1 只做登记与验证状态
-- ============================================================================

-- 48.1 列表返回 purpose / site_id
CREATE OR REPLACE FUNCTION public.list_my_domains()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_rows jsonb;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.created_at), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT id, hostname, status, verification_token, verified_at, created_at,
           purpose, site_id
    FROM public.manager_domains
    WHERE root_manager_id = v_root
  ) d;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_my_domains() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_domains() TO authenticated;

-- 48.2 新增域名：旧函数是 add_my_domain(text)，改为带默认参数的 (text, text)
--      旧 SQL 调用 add_my_domain('x') 因默认值仍然兼容。
DROP FUNCTION IF EXISTS public.add_my_domain(text);

CREATE OR REPLACE FUNCTION public.add_my_domain(p_hostname text, p_purpose text DEFAULT 'shop')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_purpose text;
  v_host text;
  v_site_id uuid;
  v_id uuid;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  v_purpose := lower(btrim(COALESCE(p_purpose, 'shop')));
  IF v_purpose NOT IN ('shop','site') THEN
    RAISE EXCEPTION '域名用途不合法' USING ERRCODE = 'P0002';
  END IF;

  v_host := lower(btrim(COALESCE(p_hostname, '')));
  v_host := regexp_replace(v_host, '^https?://', '');
  v_host := split_part(v_host, '/', 1);

  IF v_host !~ '^[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)+$' THEN
    RAISE EXCEPTION '域名格式不正确' USING ERRCODE = 'P0002';
  END IF;

  IF EXISTS (SELECT 1 FROM public.manager_domains WHERE lower(hostname) = v_host) THEN
    RAISE EXCEPTION '该域名已被占用' USING ERRCODE = '23505';
  END IF;

  -- 官网域名：挂到本商户站点（没有站点则零等待自动创建，与 site_my_overview 同策略）
  IF v_purpose = 'site' THEN
    SELECT id INTO v_site_id FROM public.merchant_sites WHERE root_manager_id = v_root;
    IF v_site_id IS NULL THEN
      INSERT INTO public.merchant_sites (root_manager_id, slug, created_by)
      VALUES (v_root, public.site_slug_allocate(v_root), auth.uid())
      RETURNING id INTO v_site_id;
    END IF;
  END IF;

  INSERT INTO public.manager_domains (root_manager_id, hostname, purpose, site_id)
  VALUES (v_root, v_host, v_purpose, v_site_id)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'id', v_id,
    'hostname', v_host,
    'status', 'pending',
    'purpose', v_purpose,
    'siteId', v_site_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.add_my_domain(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_my_domain(text, text) TO authenticated;
