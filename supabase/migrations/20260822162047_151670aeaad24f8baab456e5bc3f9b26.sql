-- =====================================================================
-- 审查修复：门店模块收尾批次
-- 1. manager_update_product：互斥校验改为「最终状态」，堵住单字段绕过
-- 2. products 表级 CHECK 兜底
-- 3. _can_order_product_in_shop：门店专供商品禁止普通商城下单（服务端拦截）
-- 4. 三个写函数收紧执行权限（撤 PUBLIC 与 anon，仅 authenticated）
-- =====================================================================

-- 1. 最终状态校验
CREATE OR REPLACE FUNCTION public.manager_update_product(p_id uuid, p_patch jsonb, p_expected_status text[] DEFAULT NULL::text[])
 RETURNS products
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            UUID := auth.uid();
  v_role           TEXT;
  v_disabled       BOOLEAN;
  v_owner          UUID;
  v_source         TEXT;
  v_cur_status     TEXT;
  v_cur_store_only BOOLEAN;
  v_cur_sale_mode  TEXT;
  v_title          TEXT;
  v_status         TEXT;
  v_sale_mode      TEXT;
  v_final_mode     TEXT;
  v_final_store    BOOLEAN;
  v_cover          JSONB;
  v_unknown_key    TEXT;
  v_row            products;
  v_allowed        CONSTANT TEXT[] := ARRAY[
    'title', 'subtitle', 'description',
    'cover_image_url', 'cover_images', 'gallery_images',
    'category', 'tags',
    'status', 'sort_weight', 'sale_mode',
    'description_doc', 'store_only'
  ];
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'forbidden: not authenticated';
  END IF;

  SELECT role::text, COALESCE(is_disabled, false)
    INTO v_role, v_disabled
  FROM profiles WHERE id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'forbidden: profile missing';
  END IF;
  IF v_role IS DISTINCT FROM 'manager' THEN
    RAISE EXCEPTION 'forbidden: manager role required';
  END IF;
  IF v_disabled THEN
    RAISE EXCEPTION 'forbidden: account disabled';
  END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'patch must be a json object';
  END IF;

  SELECT k INTO v_unknown_key
  FROM jsonb_object_keys(p_patch) AS k
  WHERE k <> ALL(v_allowed)
  LIMIT 1;
  IF v_unknown_key IS NOT NULL THEN
    RAISE EXCEPTION 'unknown patch key: %', v_unknown_key;
  END IF;

  SELECT source_type, owner_manager_id, status,
         COALESCE(store_only, false), COALESCE(sale_mode, 'cash')
    INTO v_source, v_owner, v_cur_status, v_cur_store_only, v_cur_sale_mode
  FROM products WHERE id = p_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'product not found';
  END IF;
  IF v_source <> 'manager' OR v_owner IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'forbidden: not product owner';
  END IF;

  IF p_expected_status IS NOT NULL
     AND array_length(p_expected_status, 1) > 0
     AND NOT (v_cur_status = ANY(p_expected_status)) THEN
    RAISE EXCEPTION 'product status changed';
  END IF;

  IF p_patch ? 'title' THEN
    v_title := btrim(COALESCE(p_patch->>'title', ''));
    IF v_title = '' THEN
      RAISE EXCEPTION 'product title required';
    END IF;
    IF char_length(v_title) > 200 THEN
      RAISE EXCEPTION 'product title too long (max 200)';
    END IF;
  END IF;

  IF p_patch ? 'status' THEN
    v_status := btrim(COALESCE(p_patch->>'status', ''));
    IF v_status = 'pending_review' THEN
      v_status := 'active';
    END IF;
    IF v_status NOT IN ('draft', 'active', 'archived') THEN
      RAISE EXCEPTION 'invalid manager status: %', v_status;
    END IF;
    p_patch := jsonb_set(p_patch, '{status}', to_jsonb(v_status));
  END IF;

  IF p_patch ? 'sale_mode' THEN
    v_sale_mode := btrim(COALESCE(p_patch->>'sale_mode', ''));
    IF v_sale_mode NOT IN ('cash', 'points') THEN
      RAISE EXCEPTION 'invalid sale_mode: %', v_sale_mode;
    END IF;
  END IF;

  -- 只要 sale_mode 或 store_only 任一被更新，就按补丁应用后的最终状态校验互斥，
  -- 防止「给积分商品单独打 store_only」绕过现金售卖约束
  IF p_patch ? 'sale_mode' OR p_patch ? 'store_only' THEN
    v_final_mode  := COALESCE(NULLIF(btrim(p_patch->>'sale_mode'), ''), v_cur_sale_mode);
    v_final_store := COALESCE((p_patch->>'store_only')::boolean, v_cur_store_only);
    IF v_final_mode <> 'cash' AND v_final_store THEN
      RAISE EXCEPTION '仅门店销售的商品只能现金售卖，请先关闭仅门店销售';
    END IF;
  END IF;

  IF p_patch ? 'cover_images' THEN
    v_cover := p_patch->'cover_images';
    IF jsonb_typeof(v_cover) <> 'array' THEN
      RAISE EXCEPTION 'cover_images must be a JSON array';
    END IF;
    IF jsonb_array_length(v_cover) > 4 THEN
      RAISE EXCEPTION 'cover_images can contain at most 4 entries';
    END IF;
  END IF;

  UPDATE products SET
    title           = CASE WHEN p_patch ? 'title'           THEN btrim(p_patch->>'title')                        ELSE title END,
    subtitle        = CASE WHEN p_patch ? 'subtitle'        THEN COALESCE(p_patch->>'subtitle', '')               ELSE subtitle END,
    description     = CASE WHEN p_patch ? 'description'     THEN COALESCE(p_patch->>'description', '')            ELSE description END,
    description_doc = CASE WHEN p_patch ? 'description_doc' THEN p_patch->'description_doc'                       ELSE description_doc END,
    cover_image_url = CASE WHEN p_patch ? 'cover_image_url' THEN COALESCE(p_patch->>'cover_image_url', '')        ELSE cover_image_url END,
    cover_images    = CASE WHEN p_patch ? 'cover_images'    THEN COALESCE(p_patch->'cover_images', '[]'::jsonb)   ELSE cover_images END,
    gallery_images  = CASE WHEN p_patch ? 'gallery_images'  THEN COALESCE(p_patch->'gallery_images', '[]'::jsonb) ELSE gallery_images END,
    category        = CASE WHEN p_patch ? 'category'        THEN COALESCE(NULLIF(btrim(p_patch->>'category'), ''), 'general') ELSE category END,
    tags            = CASE WHEN p_patch ? 'tags' THEN COALESCE(
                            ARRAY(SELECT jsonb_array_elements_text(p_patch->'tags')),
                            '{}'::text[]
                          ) ELSE tags END,
    status          = CASE WHEN p_patch ? 'status'      THEN btrim(p_patch->>'status')                            ELSE status END,
    sort_weight     = CASE WHEN p_patch ? 'sort_weight' THEN COALESCE((p_patch->>'sort_weight')::integer, sort_weight) ELSE sort_weight END,
    sale_mode       = CASE WHEN p_patch ? 'sale_mode'   THEN btrim(p_patch->>'sale_mode')                         ELSE sale_mode END,
    store_only      = CASE WHEN p_patch ? 'store_only'  THEN COALESCE((p_patch->>'store_only')::boolean, store_only) ELSE store_only END
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

-- 2. 表级兜底约束（存量非法行为 0，安全）
ALTER TABLE public.products
  ADD CONSTRAINT products_store_only_cash_only
  CHECK (NOT COALESCE(store_only, false) OR COALESCE(sale_mode, 'cash') = 'cash');

-- 3. 普通商城下单拦截门店专供商品（门店线下下单走 create_offline_store_order，不受影响）
CREATE OR REPLACE FUNCTION public._can_order_product_in_shop(p_product_id uuid, p_user_id uuid, p_shop_root uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_product public.products;
  v_product_root uuid;
BEGIN
  SELECT * INTO v_product FROM public.products WHERE id = p_product_id;
  IF v_product.id IS NULL OR v_product.status <> 'active' THEN
    RETURN false;
  END IF;

  -- 平台商品只在平台主店（无 shop 上下文）可买；商户店内不可下单
  IF v_product.source_type = 'platform' THEN
    RETURN p_shop_root IS NULL;
  END IF;

  -- 商户商品：归属店必须等于当前店，且该店已认证未禁用
  IF v_product.owner_manager_id IS NULL THEN
    RETURN false;
  END IF;
  v_product_root := public.get_enterprise_root_manager_id(v_product.owner_manager_id);
  IF v_product_root IS NULL OR p_shop_root IS NULL OR v_product_root <> p_shop_root THEN
    RETURN false;
  END IF;
  IF NOT public.is_public_enterprise_content_root(v_product_root) THEN
    RETURN false;
  END IF;

  -- 门店专供商品只在门店商城线下购买，普通商城不下单（主商城只展示咨询入口）
  IF COALESCE(v_product.store_only, false) THEN
    RETURN false;
  END IF;

  -- 积分商品：该店积分兑换模块开放，且下单人是本店客户（正式关系或进店会员）
  IF COALESCE(v_product.sale_mode, 'cash') = 'points' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.merchant_module_grants g
      WHERE g.manager_id = v_product_root
        AND g.module_key = 'points_exchange'
        AND g.grant_status = 'granted'
        AND g.is_enabled = TRUE
    ) THEN
      RETURN false;
    END IF;
    RETURN EXISTS (
      SELECT 1 FROM public.client_relations cr
      WHERE cr.client_id = p_user_id
        AND cr.status = 'active'
        AND public.get_enterprise_root_manager_id(cr.manager_id) = v_product_root
    ) OR EXISTS (
      SELECT 1 FROM public.shop_members sm
      WHERE sm.client_id = p_user_id
        AND sm.root_manager_id = v_product_root
    );
  END IF;

  RETURN true;
END;
$function$;

-- 4. 收紧三个商户写函数的执行权限（撤 PUBLIC 与 anon，仅 authenticated + service_role）
REVOKE ALL ON FUNCTION public.manager_create_product(text,text,text,text,jsonb,jsonb,text,text[],text,integer,text,jsonb,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.manager_create_product(text,text,text,text,jsonb,jsonb,text,text[],text,integer,text,jsonb,boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.manager_create_product(text,text,text,text,jsonb,jsonb,text,text[],text,integer,text,jsonb,boolean) TO authenticated;

REVOKE ALL ON FUNCTION public.manager_update_product(uuid,jsonb,text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.manager_update_product(uuid,jsonb,text[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.manager_update_product(uuid,jsonb,text[]) TO authenticated;

REVOKE ALL ON FUNCTION public.manager_save_product_with_sku(uuid,jsonb,text[],integer,integer,integer,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.manager_save_product_with_sku(uuid,jsonb,text[],integer,integer,integer,integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.manager_save_product_with_sku(uuid,jsonb,text[],integer,integer,integer,integer) TO authenticated;