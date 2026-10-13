-- ============================================================================
-- 商户专属 URL + 自定义域名：manager_domains 表 + 解析/管理 RPC
-- 归属 root_manager_id；hostname 唯一（忽略大小写）；验证通过前不生效。
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.manager_domains (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  hostname text NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','verified','disabled')),
  verification_token text NOT NULL DEFAULT gen_random_uuid()::text,
  verified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS manager_domains_hostname_uniq
  ON public.manager_domains (lower(hostname));
CREATE INDEX IF NOT EXISTS idx_manager_domains_root
  ON public.manager_domains (root_manager_id);

ALTER TABLE public.manager_domains ENABLE ROW LEVEL SECURITY;

-- 表不直接授权，全走 SECURITY DEFINER RPC
REVOKE ALL ON public.manager_domains FROM anon, authenticated;

-- 按访问域名解析商户（仅已验证且商户未停用）
CREATE OR REPLACE FUNCTION public.resolve_manager_by_hostname(p_hostname text)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT d.root_manager_id
  FROM public.manager_domains d
  JOIN public.managers m ON m.id = d.root_manager_id
  JOIN public.profiles p ON p.id = m.id
  WHERE lower(d.hostname) = lower(p_hostname)
    AND d.status = 'verified'
    AND p.role::text = 'manager'
    AND COALESCE(p.is_disabled, false) = false
  LIMIT 1;
$function$;

REVOKE ALL ON FUNCTION public.resolve_manager_by_hostname(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_manager_by_hostname(text) TO anon, authenticated;

-- 商户：读自己企业的域名
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
    SELECT id, hostname, status, verification_token, verified_at, created_at
    FROM public.manager_domains
    WHERE root_manager_id = v_root
  ) d;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_my_domains() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_domains() TO authenticated;

-- 商户：新增自定义域名（未验证，等平台/运维验证后生效）
CREATE OR REPLACE FUNCTION public.add_my_domain(p_hostname text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_host text;
  v_id uuid;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
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

  INSERT INTO public.manager_domains (root_manager_id, hostname)
  VALUES (v_root, v_host)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'hostname', v_host, 'status', 'pending');
END;
$function$;

REVOKE ALL ON FUNCTION public.add_my_domain(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_my_domain(text) TO authenticated;

-- 商户：删除自己企业的域名
CREATE OR REPLACE FUNCTION public.delete_my_domain(p_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
BEGIN
  v_root := public.get_enterprise_root_manager_id(auth.uid());
  IF v_root IS NULL THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.manager_domains
  WHERE id = p_id AND root_manager_id = v_root;
  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_my_domain(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_my_domain(uuid) TO authenticated;

-- 平台：读指定商户的域名
CREATE OR REPLACE FUNCTION public.admin_list_domains(p_root_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.created_at), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT id, hostname, status, verification_token, verified_at, created_at
    FROM public.manager_domains
    WHERE root_manager_id = p_root_manager_id
  ) d;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_domains(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_domains(uuid) TO authenticated;

-- 平台：验证 / 停用商户域名
CREATE OR REPLACE FUNCTION public.admin_set_domain_status(p_id uuid, p_status text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_id uuid;
  v_status text;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  IF p_status = 'verified' THEN
    UPDATE public.manager_domains
       SET status = 'verified', verified_at = now(), updated_at = now()
     WHERE id = p_id
     RETURNING id INTO v_id;
  ELSIF p_status IN ('pending','disabled') THEN
    UPDATE public.manager_domains
       SET status = p_status, verified_at = NULL, updated_at = now()
     WHERE id = p_id
     RETURNING id INTO v_id;
  ELSE
    RAISE EXCEPTION '不支持的状态' USING ERRCODE = 'P0002';
  END IF;

  SELECT status INTO v_status FROM public.manager_domains WHERE id = v_id;
  RETURN jsonb_build_object('id', v_id, 'status', v_status);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_set_domain_status(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_domain_status(uuid, text) TO authenticated;