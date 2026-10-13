-- ─────────────────────────────────────────────────────────────
-- 447/448 写 RPC 收口：在企业角色权限检查之前，先做账号有效 + 企业身份 active 两道独立校验，
-- 修复「企业主恒真 + pending 就业视为有权」导致已停用账号 / pending / left 成员可直写生产数据的越权。
-- 读 RPC（get_merchant_store_poster_settings）保持不变，仍对活跃企业成员开放。
-- ─────────────────────────────────────────────────────────────

-- 企业身份有效判定：active 就业 / active 企业主 / 无任何在职·禁用·待入职就业行的 legacy 兜底。
-- 比 has_enterprise_permission 更严：pending / left / disabled 就业一律不通过；企业主要求企业 active。
CREATE OR REPLACE FUNCTION public.is_active_enterprise_identity(uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.enterprise_employments ee
    WHERE ee.auth_user_id = uid
      AND ee.status = 'active'
  )
  OR EXISTS (
    SELECT 1 FROM public.enterprises e
    WHERE e.owner_profile_id = uid
      AND e.status = 'active'
  )
  OR (
    NOT EXISTS (
      SELECT 1 FROM public.enterprise_employments
      WHERE auth_user_id = uid
        AND status IN ('active', 'disabled', 'pending')
    )
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = uid
        AND p.role = 'manager'
        AND COALESCE(p.is_disabled, false) = false
        AND (p.parent_manager_id IS NULL OR p.sub_role = 'admin')
    )
  );
$function$;

REVOKE ALL ON FUNCTION public.is_active_enterprise_identity(uuid) FROM PUBLIC, anon, authenticated;

-- 3. 保存 RPC：仅企业超级管理员；写入前逐道校验账号有效、企业身份 active、企业角色权限位
CREATE OR REPLACE FUNCTION public.save_merchant_store_poster_settings(
  p_poster_image_url text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_url text := NULLIF(btrim(COALESCE(p_poster_image_url, '')), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM auth.users u
    WHERE u.id = v_uid
      AND (u.banned_until IS NULL OR u.banned_until <= now())
  ) THEN
    RAISE EXCEPTION '账号已被停用' USING ERRCODE = '42501';
  END IF;
  IF NOT public.is_active_enterprise_identity(v_uid) THEN
    RAISE EXCEPTION '你的企业身份未激活' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RAISE EXCEPTION '只有企业超级管理员可以设置门店海报' USING ERRCODE = '42501';
  END IF;
  IF v_url IS NOT NULL AND (char_length(v_url) > 2048 OR v_url !~ '^https://') THEN
    RAISE EXCEPTION '海报底图地址无效' USING ERRCODE = '22023';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '未找到所属企业，无法保存设置' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.merchant_store_poster_settings
    (root_manager_id, poster_image_url, updated_by, updated_at)
  VALUES (v_root, COALESCE(v_url, ''), v_uid, now())
  ON CONFLICT (root_manager_id) DO UPDATE
    SET poster_image_url = EXCLUDED.poster_image_url,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object('success', true, 'poster_image_url', v_url);
END;
$function$;

-- 4. 批量授权 RPC：给本企业全部 active 门店新增勾选（只新增，不取消已有）
CREATE OR REPLACE FUNCTION public.grant_products_to_all_stores(p_product_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_ids uuid[];
  v_product public.products;
  v_product_root uuid;
  v_pid uuid;
  v_store_count integer;
  v_product_count integer;
  v_grant_count integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM auth.users u
    WHERE u.id = v_uid
      AND (u.banned_until IS NULL OR u.banned_until <= now())
  ) THEN
    RAISE EXCEPTION '账号已被停用' USING ERRCODE = '42501';
  END IF;
  IF NOT public.is_active_enterprise_identity(v_uid) THEN
    RAISE EXCEPTION '你的企业身份未激活' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RAISE EXCEPTION '只有企业超级管理员可以批量勾选商品' USING ERRCODE = '42501';
  END IF;
  IF p_product_ids IS NULL OR coalesce(array_length(p_product_ids, 1), 0) = 0 THEN
    RAISE EXCEPTION '请至少选择一个商品' USING ERRCODE = '22023';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '未找到所属企业，无法批量勾选' USING ERRCODE = '42501';
  END IF;

  SELECT array_agg(DISTINCT pid) INTO v_ids
  FROM unnest(p_product_ids) AS ids(pid);

  FOR v_pid IN SELECT unnest(v_ids) LOOP
    SELECT pr.* INTO v_product FROM public.products pr WHERE pr.id = v_pid;
    IF NOT FOUND OR v_product.status <> 'active' THEN
      RAISE EXCEPTION '商品不存在或已下架' USING ERRCODE = '22023';
    END IF;
    IF v_product.source_type <> 'manager' THEN
      RAISE EXCEPTION '平台自营商品不能配到门店' USING ERRCODE = '22023';
    END IF;
    IF v_product.sale_mode <> 'cash' THEN
      RAISE EXCEPTION '积分兑换商品不能配到门店' USING ERRCODE = '22023';
    END IF;
    v_product_root := public.get_enterprise_root_manager_id(v_product.owner_manager_id);
    IF v_product_root IS DISTINCT FROM v_root THEN
      RAISE EXCEPTION '只能勾选本企业自己的商品' USING ERRCODE = '42501';
    END IF;
  END LOOP;

  SELECT count(*) INTO v_store_count
  FROM public.stores
  WHERE root_manager_id = v_root AND status = 'active';
  SELECT count(*) INTO v_product_count FROM unnest(v_ids);

  INSERT INTO public.store_product_grants (store_id, product_id, is_enabled, created_by)
  SELECT s.id, ids.pid, true, v_uid
  FROM public.stores s
  CROSS JOIN unnest(v_ids) AS ids(pid)
  WHERE s.root_manager_id = v_root AND s.status = 'active'
  ON CONFLICT (store_id, product_id) DO UPDATE
    SET is_enabled = true,
        updated_at = now();
  GET DIAGNOSTICS v_grant_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'success', true,
    'store_count', v_store_count,
    'product_count', v_product_count,
    'grant_count', v_grant_count
  );
END;
$function$;