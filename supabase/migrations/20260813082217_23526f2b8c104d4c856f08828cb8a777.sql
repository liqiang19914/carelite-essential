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

  -- 1. admin 全可见
  IF EXISTS (
    SELECT 1 FROM profiles WHERE id = p_user_id AND role = 'admin'
  ) THEN
    RETURN TRUE;
  END IF;

  -- 2. 平台严选 + active：所有用户可见
  IF v_source = 'platform' AND v_status = 'active' THEN
    RETURN TRUE;
  END IF;

  -- 3. 平台严选 + 非 active：仅 admin（上面已拦截）
  IF v_source = 'platform' THEN
    RETURN FALSE;
  END IF;

  -- 4. 管理师私域：作者本人可见所有状态
  IF v_source = 'manager' AND v_owner = p_user_id THEN
    RETURN TRUE;
  END IF;

  IF v_source = 'manager' AND v_status = 'active' THEN
    -- 5. 积分兑换商品：门禁独立且权威
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

    -- 6. 现金私域 active：该商户（含其企业员工）的活跃客户直接可见，
    --    不再需要 share_grants 显式授权。审核通过即上架到该商户商城。
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