-- 288：模块键白名单补 'native_login'（平台授予即生效，商户无自开关）
ALTER TABLE public.merchant_module_grants DROP CONSTRAINT IF EXISTS mmg_module_key_check;
ALTER TABLE public.merchant_module_grants ADD CONSTRAINT mmg_module_key_check
  CHECK (module_key = ANY (ARRAY[
    'shop_order_lifecycle', 'points_exchange', 'stores',
    'view_conversations', 'view_health_insights', 'view_health_records',
    'native_login'
  ]));

-- 授权 RPC 白名单同步（保留 4 参数签名）
DROP FUNCTION IF EXISTS public.admin_set_merchant_module_grant(uuid, text, boolean, text);

CREATE OR REPLACE FUNCTION public.admin_set_merchant_module_grant(p_manager_id uuid, p_module_key text, p_granted boolean, p_notes text DEFAULT NULL::text)
 RETURNS public.merchant_module_grants
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.merchant_module_grants;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '只有平台管理员可以调整商户模块授权' USING ERRCODE = '42501';
  END IF;
  IF p_module_key NOT IN ('shop_order_lifecycle', 'points_exchange', 'view_health_records', 'view_health_insights', 'view_conversations', 'stores', 'native_login') THEN
    RAISE EXCEPTION '未知的模块' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.managers WHERE id = p_manager_id) THEN
    RAISE EXCEPTION '找不到该商户' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.merchant_module_grants (
    manager_id, module_key, grant_status, is_enabled, granted_by, notes
  ) VALUES (
    p_manager_id, p_module_key,
    CASE WHEN COALESCE(p_granted, false) THEN 'granted' ELSE 'revoked' END,
    false, v_uid, p_notes
  )
  ON CONFLICT (manager_id, module_key) DO UPDATE
  SET grant_status = CASE WHEN COALESCE(p_granted, false) THEN 'granted' ELSE 'revoked' END,
      is_enabled   = CASE WHEN COALESCE(p_granted, false)
                          THEN public.merchant_module_grants.is_enabled
                          ELSE false END,
      granted_by   = v_uid,
      granted_at   = now(),
      notes        = COALESCE(p_notes, public.merchant_module_grants.notes),
      updated_at   = now()
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_set_merchant_module_grant(uuid, text, boolean, text) TO authenticated;