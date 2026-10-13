-- ─────────────────────────────────────────────────────────────
-- 447 门店海报底图设置 + 448 所有门店一键勾选商品
-- 与门店绑定设置同家族：merchant_store_binding_settings 按企业根一行；
-- 读 RPC 活跃企业成员可用，写 RPC 仅企业超级管理员（enterprise_roles）。
-- ─────────────────────────────────────────────────────────────

-- 1. 门店海报底图：root_manager_id 按企业根一行
CREATE TABLE IF NOT EXISTS public.merchant_store_poster_settings (
  root_manager_id  uuid PRIMARY KEY REFERENCES public.managers(id) ON DELETE CASCADE,
  poster_image_url text NOT NULL DEFAULT '',
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid
);

ALTER TABLE public.merchant_store_poster_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.merchant_store_poster_settings FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_store_poster_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_store_poster_settings TO service_role;

COMMENT ON TABLE public.merchant_store_poster_settings IS
  '门店海报底图设置：root_manager_id 按企业根一行；poster_image_url 空串=未配置，门店海报使用品牌主色渐变默认版式。写入一律经 RPC，仅企业超级管理员可保存。';
COMMENT ON COLUMN public.merchant_store_poster_settings.poster_image_url IS
  '门店小程序码海报底图（750×1334 参考，超出居中裁剪）；空串=未配置。';

-- 2. 读取 RPC：无行或空串返回 NULL=未配置
CREATE OR REPLACE FUNCTION public.get_merchant_store_poster_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_url text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.is_active_enterprise_content_member(v_uid) THEN
    RAISE EXCEPTION '所属企业当前不可配置，请联系企业负责人或平台处理' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT poster_image_url INTO v_url
  FROM public.merchant_store_poster_settings
  WHERE root_manager_id = v_root;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('poster_image_url', NULLIF(btrim(v_url), ''));
END;
$function$;

-- 3. 保存 RPC：仅企业超级管理员
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

  -- 逐商品校验（与 set_store_product_grant 同口径），任一不合规即中止
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

-- 5. 授权收口：仅 authenticated 可执行
REVOKE ALL ON FUNCTION public.get_merchant_store_poster_settings() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_merchant_store_poster_settings() TO authenticated;
REVOKE ALL ON FUNCTION public.save_merchant_store_poster_settings(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_merchant_store_poster_settings(text) TO authenticated;
REVOKE ALL ON FUNCTION public.grant_products_to_all_stores(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.grant_products_to_all_stores(uuid[]) TO authenticated;