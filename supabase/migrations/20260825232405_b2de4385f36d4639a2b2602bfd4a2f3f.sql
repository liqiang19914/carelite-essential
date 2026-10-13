-- ============================================================================
-- 平台「域名映射」管理：CNAME 目标配置 + 平台代加/删域名受控接口
-- ============================================================================

INSERT INTO public.system_settings (key, value, description) VALUES
  ('domain_cname_target', 'alias-qcloud.superun.com', '自定义域名 CNAME 解析目标（平台接入层域名）')
ON CONFLICT (key) DO NOTHING;

-- 平台：代商户新增自定义域名（默认 pending，等验证后生效）
CREATE OR REPLACE FUNCTION public.admin_add_domain(p_root_manager_id uuid, p_hostname text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_host text;
  v_id uuid;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  IF NOT public.is_merchant_root(p_root_manager_id) THEN
    RAISE EXCEPTION '目标商户不存在或不是商户根' USING ERRCODE = 'P0002';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = p_root_manager_id AND COALESCE(is_disabled, false) = true
  ) THEN
    RAISE EXCEPTION '目标商户已停用，无法为其添加域名' USING ERRCODE = 'P0002';
  END IF;

  v_host := lower(btrim(COALESCE(p_hostname, '')));
  v_host := regexp_replace(v_host, '^https?://', '');
  v_host := split_part(v_host, '/', 1);

  IF v_host !~ '^[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)+$' THEN
    RAISE EXCEPTION '域名格式不正确' USING ERRCODE = 'P0002';
  END IF;

  IF char_length(v_host) > 253 THEN
    RAISE EXCEPTION '域名过长' USING ERRCODE = 'P0002';
  END IF;

  IF EXISTS (
    SELECT 1 FROM unnest(string_to_array(v_host, '.')) AS label
    WHERE char_length(label) > 63
  ) THEN
    RAISE EXCEPTION '域名标签过长' USING ERRCODE = 'P0002';
  END IF;

  IF v_host ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' THEN
    RAISE EXCEPTION '不支持使用 IP 地址作为域名' USING ERRCODE = 'P0002';
  END IF;

  IF EXISTS (SELECT 1 FROM public.manager_domains WHERE lower(hostname) = v_host) THEN
    RAISE EXCEPTION '该域名已被占用' USING ERRCODE = '23505';
  END IF;

  BEGIN
    INSERT INTO public.manager_domains (root_manager_id, hostname)
    VALUES (p_root_manager_id, v_host)
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION '该域名已被占用' USING ERRCODE = '23505';
  END;

  RETURN (SELECT to_jsonb(d) FROM public.manager_domains d WHERE d.id = v_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_add_domain(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_add_domain(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_add_domain(uuid, text) TO authenticated;

-- 平台：删除域名映射记录（删除后立即失效，访问回落到平台品牌）
CREATE OR REPLACE FUNCTION public.admin_delete_domain(p_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_id uuid;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.manager_domains
  WHERE id = p_id
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION '域名不存在或已被删除' USING ERRCODE = 'P0002';
  END IF;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_delete_domain(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_delete_domain(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_domain(uuid) TO authenticated;