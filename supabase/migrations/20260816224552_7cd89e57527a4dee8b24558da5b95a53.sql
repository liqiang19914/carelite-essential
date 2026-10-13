-- 平台读商户域名：入口可传企业根或员工管理师 id，服务端统一换算成企业根。
CREATE OR REPLACE FUNCTION public.admin_list_domains(p_root_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_rows jsonb;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION '无权限操作' USING ERRCODE = '42501';
  END IF;

  v_root := public.get_enterprise_root_manager_id(p_root_manager_id);
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