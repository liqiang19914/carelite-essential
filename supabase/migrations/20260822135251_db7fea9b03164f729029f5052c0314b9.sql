-- ============================================================================
-- 门店体系 RPC 组 A：公开查询 / 认领 / 商户管理 / 入驻申请 / 平台治理
-- 全部 SECURITY DEFINER + 显式归属校验；中文错误直接可执行。
-- ============================================================================

-- ── 短码生成（10 位，字母数字）───────────────────────────────────────
CREATE OR REPLACE FUNCTION public._gen_store_code()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_alphabet TEXT := 'abcdefghijklmnopqrstuvwxyz0123456789';
  v_code TEXT;
  v_i INTEGER;
BEGIN
  FOR v_i IN 1..20 LOOP
    v_code := '';
    FOR v_j IN 1..10 LOOP
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * 36)::int, 1);
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM public.stores WHERE short_code = v_code) THEN
      RETURN v_code;
    END IF;
  END LOOP;
  RAISE EXCEPTION '短码生成失败，请重试';
END;
$function$;

REVOKE ALL ON FUNCTION public._gen_store_code() FROM PUBLIC;

-- ── 公开：短码 → 门店公开信息（anon；不暴露经营账号）──────────────
CREATE OR REPLACE FUNCTION public.get_public_store_by_code(p_code TEXT)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_store public.stores%ROWTYPE;
BEGIN
  IF p_code IS NULL OR btrim(p_code) = '' THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_store FROM public.stores WHERE short_code = btrim(p_code);
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN json_build_object(
    'id', v_store.id,
    'short_code', v_store.short_code,
    'name', v_store.name,
    'status', v_store.status,
    'root_manager_id', v_store.root_manager_id,
    'receipt_qr_url', v_store.receipt_qr_url,
    'disabled_at', v_store.disabled_at
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_store_by_code(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_store_by_code(TEXT) TO anon, authenticated;

-- ── 经营者认领（手机号登录即证明；不覆盖任何既有绑定）─────────────
CREATE OR REPLACE FUNCTION public.claim_store(p_store_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_store public.stores%ROWTYPE;
  v_phone TEXT;
  v_norm TEXT;
  v_store_norm TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_store FROM public.stores WHERE id = p_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '门店不存在' USING ERRCODE = '22023';
  END IF;
  IF v_store.status <> 'active' THEN
    RAISE EXCEPTION '这家门店已暂停营业，无法认领' USING ERRCODE = '22023';
  END IF;
  IF v_store.operator_user_id IS NOT NULL THEN
    RAISE EXCEPTION '这家门店已经有经营账号了' USING ERRCODE = '22023';
  END IF;

  SELECT phone INTO v_phone FROM public.profiles WHERE id = v_uid;
  v_norm := regexp_replace(COALESCE(v_phone, ''), '[^0-9]', '', 'g');
  v_store_norm := regexp_replace(COALESCE(v_store.phone, ''), '[^0-9]', '', 'g');
  IF v_norm = '' OR v_norm <> v_store_norm THEN
    RAISE EXCEPTION '只有门店登记的手机号本人才能认领这家店' USING ERRCODE = '42501';
  END IF;

  UPDATE public.stores
     SET operator_user_id = v_uid,
         updated_at = now()
   WHERE id = v_store.id;

  RETURN json_build_object('success', true, 'store_id', v_store.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.claim_store(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_store(UUID) TO authenticated;

-- ── 经营者：我的门店（工作台登录入口用）──────────────────────────
CREATE OR REPLACE FUNCTION public.list_my_stores()
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_items JSON;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT s.id, s.short_code, s.name, s.status,
           s.root_manager_id, s.receipt_qr_url, s.created_at
    FROM public.stores s
    WHERE s.operator_user_id = v_uid
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;

REVOKE ALL ON FUNCTION public.list_my_stores() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_stores() TO authenticated;

-- ── 商户：企业门店列表 ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.list_enterprise_stores()
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_items JSON;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '只有商户账号可以管理门店' USING ERRCODE = '42501';
  END IF;

  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT s.id, s.short_code, s.name, s.phone, s.status,
           s.receipt_qr_url, s.payment_merchant_no, s.created_source,
           s.disabled_at, s.created_at,
           (s.operator_user_id IS NULL) AS awaiting_claim,
           op.nickname AS operator_nickname
    FROM public.stores s
    LEFT JOIN public.profiles op ON op.id = s.operator_user_id
    WHERE s.root_manager_id = v_root
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_stores() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_enterprise_stores() TO authenticated;

-- ── 商户编辑门店资料（名字/电话/收款码/商户号登记）────────────────
CREATE OR REPLACE FUNCTION public.update_store_profile(
  p_store_id UUID,
  p_name TEXT,
  p_phone TEXT,
  p_receipt_qr_url TEXT,
  p_payment_merchant_no TEXT
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_store public.stores%ROWTYPE;
  v_name TEXT := btrim(COALESCE(p_name, ''));
  v_phone TEXT := btrim(COALESCE(p_phone, ''));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_store FROM public.stores WHERE id = p_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '门店不存在' USING ERRCODE = '22023';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS DISTINCT FROM v_store.root_manager_id
     AND v_store.operator_user_id IS DISTINCT FROM v_uid
     AND NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '你没有管理这家门店的权限' USING ERRCODE = '42501';
  END IF;

  IF v_name = '' OR char_length(v_name) > 60 THEN
    RAISE EXCEPTION '门店名称不能为空且不超过 60 字' USING ERRCODE = '22023';
  END IF;
  IF v_phone !~ '^1[3-9][0-9]{9}$' THEN
    RAISE EXCEPTION '手机号格式不正确' USING ERRCODE = '22023';
  END IF;
  IF char_length(COALESCE(p_receipt_qr_url, '')) > 2000 THEN
    RAISE EXCEPTION '收款码链接过长' USING ERRCODE = '22023';
  END IF;
  IF char_length(COALESCE(p_payment_merchant_no, '')) > 64 THEN
    RAISE EXCEPTION '商户号登记信息过长' USING ERRCODE = '22023';
  END IF;

  UPDATE public.stores
     SET name = v_name,
         phone = v_phone,
         receipt_qr_url = COALESCE(p_receipt_qr_url, receipt_qr_url),
         payment_merchant_no = COALESCE(p_payment_merchant_no, payment_merchant_no),
         updated_at = now()
   WHERE id = v_store.id;

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.update_store_profile(UUID, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_store_profile(UUID, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- ── 商户/平台：停用与恢复门店（停用只撤经营权，历史订单保留）──────
CREATE OR REPLACE FUNCTION public.set_store_status(p_store_id UUID, p_status TEXT)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_store public.stores%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('active','disabled') THEN
    RAISE EXCEPTION '状态值不合法' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_store FROM public.stores WHERE id = p_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '门店不存在' USING ERRCODE = '22023';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS DISTINCT FROM v_store.root_manager_id AND NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '你没有管理这家门店的权限' USING ERRCODE = '42501';
  END IF;

  UPDATE public.stores
     SET status = p_status,
         disabled_at = CASE WHEN p_status = 'disabled' THEN now() ELSE NULL END,
         updated_at = now()
   WHERE id = v_store.id;

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.set_store_status(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_store_status(UUID, TEXT) TO authenticated;

-- ── 商户：门店商品勾选（子集授权；校验商品属本企业根的现金实物商品）─
CREATE OR REPLACE FUNCTION public.set_store_product_grant(
  p_store_id UUID,
  p_product_id UUID,
  p_is_enabled BOOLEAN
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_store public.stores%ROWTYPE;
  v_product public.products%ROWTYPE;
  v_product_root UUID;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_store FROM public.stores WHERE id = p_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '门店不存在' USING ERRCODE = '22023';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS DISTINCT FROM v_store.root_manager_id AND NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '你没有管理这家门店的权限' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_product FROM public.products WHERE id = p_product_id;
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
  IF v_product_root IS DISTINCT FROM v_store.root_manager_id THEN
    RAISE EXCEPTION '只能勾选本企业自己的商品' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.store_product_grants (store_id, product_id, is_enabled, created_by)
  VALUES (v_store.id, v_product.id, COALESCE(p_is_enabled, true), v_uid)
  ON CONFLICT (store_id, product_id)
  DO UPDATE SET is_enabled = COALESCE(p_is_enabled, true),
                updated_at = now();

  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.set_store_product_grant(UUID, UUID, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_store_product_grant(UUID, UUID, BOOLEAN) TO authenticated;

-- ── 商户/经营者：门店已勾选商品 id 列表 ──────────────────────────
CREATE OR REPLACE FUNCTION public.list_store_granted_products(p_store_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_store public.stores%ROWTYPE;
  v_items JSON;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_store FROM public.stores WHERE id = p_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '门店不存在' USING ERRCODE = '22023';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS DISTINCT FROM v_store.root_manager_id
     AND v_store.operator_user_id IS DISTINCT FROM v_uid
     AND NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '你没有查看这家门店的权限' USING ERRCODE = '42501';
  END IF;

  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT g.product_id, g.is_enabled, g.updated_at
    FROM public.store_product_grants g
    WHERE g.store_id = v_store.id
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;

REVOKE ALL ON FUNCTION public.list_store_granted_products(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_store_granted_products(UUID) TO authenticated;

-- ── C 端：提交入驻申请 ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.submit_store_application(
  p_store_name TEXT,
  p_contact_name TEXT,
  p_contact_phone TEXT,
  p_root_manager_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_name TEXT := btrim(COALESCE(p_store_name, ''));
  v_contact TEXT := btrim(COALESCE(p_contact_name, ''));
  v_phone TEXT := btrim(COALESCE(p_contact_phone, ''));
  v_row public.merchant_store_applications%ROWTYPE;
  v_phone_owned BOOLEAN;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF v_name = '' OR char_length(v_name) > 60 THEN
    RAISE EXCEPTION '门店名称不能为空且不超过 60 字' USING ERRCODE = '22023';
  END IF;
  IF v_contact = '' OR char_length(v_contact) > 50 THEN
    RAISE EXCEPTION '联系人姓名不能为空且不超过 50 字' USING ERRCODE = '22023';
  END IF;
  IF v_phone !~ '^1[3-9][0-9]{9}$' THEN
    RAISE EXCEPTION '手机号格式不正确' USING ERRCODE = '22023';
  END IF;
  IF p_root_manager_id IS NULL THEN
    RAISE EXCEPTION '请先选择要入驻的商户' USING ERRCODE = '22023';
  END IF;

  -- 商户存在 + 认证通过 + 门店模块双闸门开启
  IF NOT EXISTS (SELECT 1 FROM public.managers m WHERE m.id = p_root_manager_id AND m.certification_status = 'approved') THEN
    RAISE EXCEPTION '这家商户尚未通过平台认证' USING ERRCODE = '22023';
  END IF;
  IF NOT public._store_module_on(p_root_manager_id) THEN
    RAISE EXCEPTION '这家商户还没有开放门店入驻' USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE regexp_replace(p.phone, '[^0-9]', '', 'g') = regexp_replace(v_phone, '[^0-9]', '', 'g')
  ) INTO v_phone_owned;

  INSERT INTO public.merchant_store_applications
    (root_manager_id, applicant_user_id, store_name, contact_name, contact_phone)
  VALUES (p_root_manager_id, v_uid, v_name, v_contact, v_phone)
  RETURNING * INTO v_row;

  RETURN json_build_object(
    'success', true,
    'application_id', v_row.id,
    'phone_registered', COALESCE(v_phone_owned, false)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.submit_store_application(TEXT, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_store_application(TEXT, TEXT, TEXT, UUID) TO authenticated;

-- ── C 端：我的入驻申请 ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.list_my_store_applications()
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_items JSON;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT a.id, a.root_manager_id, a.store_name, a.contact_name, a.contact_phone,
           a.status, a.rejection_reason, a.created_store_id, a.created_at,
           m.business_name AS merchant_name
    FROM public.merchant_store_applications a
    LEFT JOIN public.managers m ON m.id = a.root_manager_id
    WHERE a.applicant_user_id = v_uid
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;

REVOKE ALL ON FUNCTION public.list_my_store_applications() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_my_store_applications() TO authenticated;

-- ── 商户：入驻申请列表 ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.list_merchant_store_applications(p_status TEXT DEFAULT 'pending')
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_items JSON;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '只有商户账号可以审核入驻申请' USING ERRCODE = '42501';
  END IF;

  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT a.id, a.store_name, a.contact_name, a.contact_phone,
           a.status, a.rejection_reason, a.reviewed_at, a.created_at,
           p.nickname AS applicant_nickname
    FROM public.merchant_store_applications a
    LEFT JOIN public.profiles p ON p.id = a.applicant_user_id
    WHERE a.root_manager_id = v_root
      AND (p_status = 'all' OR a.status = p_status)
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;

REVOKE ALL ON FUNCTION public.list_merchant_store_applications(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_merchant_store_applications(TEXT) TO authenticated;

-- ── 商户：审核入驻申请（通过 = 同事务建店并绑定申请人）────────────
CREATE OR REPLACE FUNCTION public.review_store_application(
  p_application_id UUID,
  p_action TEXT,
  p_reason TEXT DEFAULT ''
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_root UUID;
  v_app public.merchant_store_applications%ROWTYPE;
  v_store_id UUID;
  v_code TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF p_action NOT IN ('approve','reject') THEN
    RAISE EXCEPTION '操作不合法' USING ERRCODE = '22023';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '只有商户账号可以审核入驻申请' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_app
  FROM public.merchant_store_applications
  WHERE id = p_application_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '申请不存在' USING ERRCODE = '22023';
  END IF;
  IF v_app.root_manager_id IS DISTINCT FROM v_root THEN
    RAISE EXCEPTION '你不能审核其他商户的申请' USING ERRCODE = '42501';
  END IF;
  IF v_app.status <> 'pending' THEN
    RAISE EXCEPTION '这份申请已经处理过了' USING ERRCODE = '22023';
  END IF;

  IF p_action = 'reject' THEN
    UPDATE public.merchant_store_applications
       SET status = 'rejected',
           rejection_reason = btrim(COALESCE(p_reason, '')),
           reviewed_by = v_uid,
           reviewed_at = now(),
           updated_at = now()
     WHERE id = v_app.id;
    RETURN json_build_object('success', true, 'action', 'rejected');
  END IF;

  -- approve：同事务建店（经营者 = 申请人本人，手机号用申请人档案手机号）
  v_code := public._gen_store_code();
  INSERT INTO public.stores
    (root_manager_id, operator_user_id, short_code, name, phone,
     status, created_source, created_by)
  VALUES
    (v_app.root_manager_id, v_app.applicant_user_id, v_code, v_app.store_name,
     v_app.contact_phone, 'active', 'application', v_uid)
  RETURNING id INTO v_store_id;

  UPDATE public.merchant_store_applications
     SET status = 'approved',
         reviewed_by = v_uid,
         reviewed_at = now(),
         created_store_id = v_store_id,
         updated_at = now()
   WHERE id = v_app.id;

  RETURN json_build_object('success', true, 'action', 'approved', 'store_id', v_store_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.review_store_application(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.review_store_application(UUID, TEXT, TEXT) TO authenticated;

-- ── C 端：撤销自己的待审申请 ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.cancel_store_application(p_application_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_app public.merchant_store_applications%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_app
  FROM public.merchant_store_applications
  WHERE id = p_application_id;
  IF NOT FOUND OR v_app.applicant_user_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION '申请不存在' USING ERRCODE = '22023';
  END IF;
  IF v_app.status <> 'pending' THEN
    RAISE EXCEPTION '这份申请已经处理过了，无法撤销' USING ERRCODE = '22023';
  END IF;
  UPDATE public.merchant_store_applications
     SET status = 'cancelled', updated_at = now()
   WHERE id = v_app.id;
  RETURN json_build_object('success', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.cancel_store_application(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_store_application(UUID) TO authenticated;

-- ── 平台：门店只读治理列表 ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_list_stores(
  p_limit INTEGER DEFAULT 20,
  p_offset INTEGER DEFAULT 0,
  p_status TEXT DEFAULT 'all',
  p_root_manager_id UUID DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_items JSON;
  v_total INTEGER;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '只有平台管理员可以查看' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM public.stores s
  WHERE (p_status = 'all' OR s.status = p_status)
    AND (p_root_manager_id IS NULL OR s.root_manager_id = p_root_manager_id);

  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT s.id, s.short_code, s.name, s.phone, s.status, s.created_source,
           s.disabled_at, s.created_at,
           s.root_manager_id, m.business_name AS merchant_name,
           op.nickname AS operator_nickname
    FROM public.stores s
    LEFT JOIN public.managers m ON m.id = s.root_manager_id
    LEFT JOIN public.profiles op ON op.id = s.operator_user_id
    WHERE (p_status = 'all' OR s.status = p_status)
      AND (p_root_manager_id IS NULL OR s.root_manager_id = p_root_manager_id)
    ORDER BY s.created_at DESC
    LIMIT GREATEST(LEAST(p_limit, 100), 1)
    OFFSET GREATEST(p_offset, 0)
  ) t;

  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON), 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_stores(INTEGER, INTEGER, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_stores(INTEGER, INTEGER, TEXT, UUID) TO authenticated;