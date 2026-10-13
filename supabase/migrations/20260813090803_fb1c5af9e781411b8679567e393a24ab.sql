-- 修复2：can_view_product 绑定调用者身份，撤销匿名执行权限
CREATE OR REPLACE FUNCTION public.can_view_product(p_product_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_source TEXT;
  v_owner UUID;
  v_status TEXT;
  v_sale_mode TEXT;
  v_root UUID;
BEGIN
  -- 防探测：普通登录/匿名调用只能查自己；service_role / 内部 SECURITY DEFINER 调用不受限
  IF session_user IN ('anon', 'authenticated')
     AND p_user_id IS DISTINCT FROM (SELECT auth.uid()) THEN
    RETURN FALSE;
  END IF;

  IF p_product_id IS NULL OR p_user_id IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT source_type, owner_manager_id, status, COALESCE(sale_mode, 'cash')
    INTO v_source, v_owner, v_status, v_sale_mode
    FROM products
    WHERE id = p_product_id;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  IF EXISTS (
    SELECT 1 FROM profiles WHERE id = p_user_id AND role = 'admin'
  ) THEN
    RETURN TRUE;
  END IF;

  IF v_source = 'platform' AND v_status = 'active' THEN
    RETURN TRUE;
  END IF;

  IF v_source = 'platform' THEN
    RETURN FALSE;
  END IF;

  IF v_source = 'manager' AND v_owner = p_user_id THEN
    RETURN TRUE;
  END IF;

  IF v_source = 'manager' AND v_status = 'active' THEN
    IF v_sale_mode = 'points' THEN
      IF v_owner IS NULL THEN
        RETURN FALSE;
      END IF;
      v_root := get_enterprise_root_manager_id(v_owner);
      IF v_root IS NULL THEN
        RETURN FALSE;
      END IF;
      RETURN EXISTS (
        SELECT 1 FROM merchant_module_grants g
        WHERE g.manager_id = v_root
          AND g.module_key = 'points_exchange'
          AND g.grant_status = 'granted'
          AND g.is_enabled = TRUE
      ) AND EXISTS (
        SELECT 1 FROM client_relations cr
        WHERE cr.client_id = p_user_id
          AND cr.status = 'active'
          AND get_enterprise_root_manager_id(cr.manager_id) = v_root
      );
    END IF;

    IF v_owner IS NOT NULL AND EXISTS (
      SELECT 1 FROM client_relations cr
      WHERE cr.client_id = p_user_id
        AND cr.status = 'active'
        AND get_enterprise_root_manager_id(cr.manager_id) = get_enterprise_root_manager_id(v_owner)
    ) THEN
      RETURN TRUE;
    END IF;
  END IF;

  RETURN FALSE;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.can_view_product(uuid, uuid) FROM anon;