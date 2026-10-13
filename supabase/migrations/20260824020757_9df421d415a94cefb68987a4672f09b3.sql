-- ── 我的线下单：OEM 只看本店单，平台主 App 空态 ──
DROP FUNCTION IF EXISTS public.list_my_offline_orders();

CREATE OR REPLACE FUNCTION public.list_my_offline_orders(p_shop_root uuid DEFAULT NULL::uuid)
 RETURNS json
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

  IF p_shop_root IS NULL THEN
    RETURN json_build_object('items', '[]'::JSON);
  END IF;

  v_root := public.get_enterprise_root_manager_id(p_shop_root);
  IF v_root IS NULL THEN
    RETURN json_build_object('items', '[]'::JSON);
  END IF;

  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT o.id, o.out_trade_no, o.verify_code,
           o.product_title_snapshot, o.cover_image_snapshot,
           o.total_amount_cents, o.quantity, o.created_at,
           o.offline_status, o.offline_claimed_at, o.verified_at,
           o.store_name_snapshot, o.receipt_qr_url_snapshot, o.requires_shipping_snapshot,
           s.address AS store_address,
           s.phone AS store_phone
    FROM public.orders o
    LEFT JOIN public.stores s ON s.id = o.store_id
    WHERE o.user_id = v_uid
      AND o.payment_channel = 'offline_store'
      AND o.owner_manager_id_snapshot IS NOT NULL
      AND public.get_enterprise_root_manager_id(o.owner_manager_id_snapshot) = v_root
    ORDER BY o.created_at DESC
    LIMIT 100
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;

GRANT EXECUTE ON FUNCTION public.list_my_offline_orders(uuid) TO authenticated, anon, service_role;

-- ── 我的门店绑定：OEM 只看本企业门店，平台主 App 空态 ──
DROP FUNCTION IF EXISTS public.list_my_bound_stores();

CREATE OR REPLACE FUNCTION public.list_my_bound_stores(p_shop_root uuid DEFAULT NULL::uuid)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_root uuid;
  v_items json;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;

  if p_shop_root is null then
    return json_build_object('items', '[]'::json);
  end if;

  v_root := public.get_enterprise_root_manager_id(p_shop_root);
  if v_root is null then
    return json_build_object('items', '[]'::json);
  end if;

  select json_agg(t order by t.bound_at desc) into v_items
  from (
    select s.id as store_id, s.name, s.address, s.phone,
           s.storefront_image_url, s.short_code, s.receipt_qr_url,
           m.business_name as brand_name,
           b.bound_at, b.last_visit_at
    from public.user_store_bindings b
    join public.stores s on s.id = b.store_id
    left join public.managers m on m.id = s.root_manager_id
    where b.user_id = v_uid and b.status = 'active'
      and public.get_enterprise_root_manager_id(s.root_manager_id) = v_root
  ) t;
  return json_build_object('items', coalesce(v_items, '[]'::json));
end;
$function$;

GRANT EXECUTE ON FUNCTION public.list_my_bound_stores(uuid) TO authenticated, anon, service_role;

-- ── 我的健管师卡：OEM 按企业根过滤，平台主 App 只取平台自身健管师 ──
DROP FUNCTION IF EXISTS public.get_my_bound_manager_card();

CREATE OR REPLACE FUNCTION public.get_my_bound_manager_card(p_shop_root uuid DEFAULT NULL::uuid)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid UUID;
  v_scope_root UUID;
  v_manager_id UUID;
  v_card JSON;
  v_doc_total INTEGER;
  v_doc_ready INTEGER;
  v_doc_failed INTEGER;
  v_doc_indexing INTEGER;
  v_is_bound BOOLEAN;
  v_source TEXT;
  v_example_uid CONSTANT UUID := '00000000-0000-0000-0000-00000000a001';
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_shop_root IS NULL THEN
    SELECT id INTO v_scope_root FROM managers WHERE is_platform_root = true LIMIT 1;
  ELSE
    v_scope_root := public.get_enterprise_root_manager_id(p_shop_root);
  END IF;
  IF v_scope_root IS NULL THEN
    v_scope_root := v_example_uid;
    v_is_bound := false;
    v_source := 'example';
  END IF;

  IF v_source IS DISTINCT FROM 'example' THEN
    SELECT cr.manager_id INTO v_manager_id
    FROM client_relations cr
    WHERE cr.client_id = v_uid AND cr.status = 'active'
      AND public.get_enterprise_root_manager_id(cr.manager_id) = v_scope_root
    ORDER BY cr.updated_at DESC NULLS LAST
    LIMIT 1;

    IF v_manager_id IS NULL THEN
      v_manager_id := v_example_uid;
      v_is_bound := false;
      v_source := 'example';
    ELSE
      v_is_bound := true;
      v_source := 'bound';
    END IF;
  END IF;

  SELECT public.get_public_manager_card(v_manager_id) INTO v_card;
  IF v_card IS NULL THEN
    RETURN json_build_object(
      'card', NULL,
      'knowledge', json_build_object(
        'total_documents', 0,
        'ready_documents', 0,
        'failed_documents', 0,
        'indexing_documents', 0,
        'has_knowledge', false
      ),
      'source', v_source,
      'is_bound', v_is_bound
    );
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE TRUE),
    COUNT(*) FILTER (WHERE status = 'ready'),
    COUNT(*) FILTER (WHERE status = 'failed'),
    COUNT(*) FILTER (WHERE status IN ('uploading','indexing'))
  INTO v_doc_total, v_doc_ready, v_doc_failed, v_doc_indexing
  FROM manager_knowledge_documents
  WHERE manager_id = v_manager_id;

  RETURN json_build_object(
    'card', v_card,
    'knowledge', json_build_object(
      'total_documents', COALESCE(v_doc_total, 0),
      'ready_documents', COALESCE(v_doc_ready, 0),
      'failed_documents', COALESCE(v_doc_failed, 0),
      'indexing_documents', COALESCE(v_doc_indexing, 0),
      'has_knowledge', COALESCE(v_doc_ready, 0) > 0
    ),
    'source', v_source,
    'is_bound', v_is_bound
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_my_bound_manager_card(uuid) TO authenticated, anon, service_role;

-- ── 体成分单条读取：所有权 + 品牌作用域校验 ──
CREATE OR REPLACE FUNCTION public.get_body_composition_detail(p_composition_id uuid, p_shop_root uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.body_compositions;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT b.* INTO v_row
  FROM public.body_compositions b
  JOIN public.health_records h ON h.id = b.record_id
  WHERE b.id = p_composition_id AND h.user_id = v_uid;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION '记录不存在' USING ERRCODE = '22023';
  END IF;

  IF p_shop_root IS NULL THEN
    IF v_row.oem_manager_id IS NOT NULL THEN
      RAISE EXCEPTION '记录不存在' USING ERRCODE = '22023';
    END IF;
  ELSE
    IF v_row.oem_manager_id IS NOT NULL
       AND public.get_enterprise_root_manager_id(v_row.oem_manager_id)
           IS DISTINCT FROM public.get_enterprise_root_manager_id(p_shop_root) THEN
      RAISE EXCEPTION '记录不存在' USING ERRCODE = '22023';
    END IF;
  END IF;

  RETURN to_jsonb(v_row);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_body_composition_detail(uuid, uuid) TO authenticated, anon, service_role;