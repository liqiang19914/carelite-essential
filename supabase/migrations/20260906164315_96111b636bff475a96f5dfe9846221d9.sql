-- 442/443 门店客户映射、顾客门店转移与顾客维度订单查询
-- Query Design Plan:
--   Op1 list_enterprise_store_bindings：商户后台「客户映射」按店查看本企业全部顾客绑定（明文手机号）。
--       actor=企业超管（has_enterprise_permission('enterprise_roles')）；owner=p_shop_root 必须等于调用者企业根；
--       join user_store_bindings(active)×stores(root=p_shop_root)×profiles，按店名+绑定时间排序，商户级小基数全量返回。
--   Op2 transfer_store_customer：商户后台把顾客的有效绑定转移至本企业另一家店。
--       actor 同上；目标店与当前 active 绑定店都必须属于调用者企业根；并发=按用户 advisory 事务锁（与
--       bind_user_to_store 同一把）+ active 行单表 FOR UPDATE；写入=旧绑定置 unbound + upsert active，
--       由 one_active 部分唯一索引保证单 active；幂等（已是该店 active 直接成功）。
--   Op3 list_my_store_orders 扩展 p_user_id（默认 NULL，参数表末位）：门禁与角色口径不变，
--       仅在 SQL 内追加 o.user_id = p_user_id 过滤；NULL 时行为与旧签名完全一致；服务端只看调用者门店。

-- 1. 商户后台客户映射列表（明文手机号，仅企业超管）
CREATE OR REPLACE FUNCTION public.list_enterprise_store_bindings(p_shop_root uuid)
RETURNS json
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_items json;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RAISE EXCEPTION '只有企业超级管理员可以查看客户映射' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '未找到所属企业，无法查看客户映射' USING ERRCODE = '42501';
  END IF;
  IF p_shop_root IS NULL OR p_shop_root <> v_root THEN
    RAISE EXCEPTION '只能查看本企业的客户映射' USING ERRCODE = '42501';
  END IF;

  SELECT json_agg(t ORDER BY t.store_name, t.bound_at DESC) INTO v_items
  FROM (
    SELECT b.store_id,
           s.name AS store_name,
           p.id AS user_id,
           p.nickname,
           p.avatar_url,
           p.phone,
           b.bound_at,
           b.last_visit_at
    FROM public.user_store_bindings b
    JOIN public.stores s ON s.id = b.store_id AND s.root_manager_id = v_root
    JOIN public.profiles p ON p.id = b.user_id
    WHERE b.status = 'active'
  ) t;

  RETURN json_build_object('items', COALESCE(v_items, '[]'::json));
END;
$function$;

-- 2. 顾客门店转移（仅企业超管；旧绑定与本企业校验同事务收口）
CREATE OR REPLACE FUNCTION public.transfer_store_customer(p_user_id uuid, p_to_store_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_to_store public.stores%ROWTYPE;
  v_current_store_id uuid;
  v_current_store_root uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RAISE EXCEPTION '只有企业超级管理员可以转移顾客门店' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '未找到所属企业，无法转移顾客' USING ERRCODE = '42501';
  END IF;
  IF p_user_id IS NULL OR p_to_store_id IS NULL THEN
    RAISE EXCEPTION '参数不完整，无法转移顾客' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_to_store FROM public.stores WHERE id = p_to_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '目标门店不存在' USING ERRCODE = '22023';
  END IF;
  IF v_to_store.root_manager_id <> v_root THEN
    RAISE EXCEPTION '目标门店不属于本企业，不能转移' USING ERRCODE = '42501';
  END IF;

  -- 与 bind_user_to_store 同一把按用户的 advisory 锁，串行化同一顾客的绑定变更
  PERFORM pg_advisory_xact_lock(hashtext('user_store_binding:' || p_user_id::text));

  SELECT b.store_id INTO v_current_store_id
  FROM public.user_store_bindings b
  WHERE b.user_id = p_user_id AND b.status = 'active'
  LIMIT 1
  FOR UPDATE;

  IF v_current_store_id IS NULL THEN
    RAISE EXCEPTION '该顾客当前没有有效的门店绑定，无法转移' USING ERRCODE = '22023';
  END IF;

  SELECT s.root_manager_id INTO v_current_store_root
  FROM public.stores s
  WHERE s.id = v_current_store_id;
  IF v_current_store_root IS DISTINCT FROM v_root THEN
    RAISE EXCEPTION '该顾客当前绑定不属于本企业，不能转移' USING ERRCODE = '42501';
  END IF;

  IF v_current_store_id = p_to_store_id THEN
    RETURN json_build_object('success', true, 'already', true);
  END IF;

  UPDATE public.user_store_bindings
     SET status = 'unbound', updated_at = now()
   WHERE user_id = p_user_id
     AND store_id = v_current_store_id
     AND status = 'active';

  INSERT INTO public.user_store_bindings (user_id, store_id, status, bound_at, last_visit_at, created_at)
  VALUES (p_user_id, p_to_store_id, 'active', now(), now(), now())
  ON CONFLICT (user_id, store_id)
  DO UPDATE SET status = 'active', last_visit_at = now(), updated_at = now();

  RETURN json_build_object('success', true, 'already', false);
END;
$function$;

-- 3. 顾客维度订单查询：list_my_store_orders 追加 p_user_id（默认 NULL，末位）
-- 旧 4 参签名先在新 5 参签名就位后删除，避免 PostgREST 命名参数双命中歧义
CREATE OR REPLACE FUNCTION public.list_my_store_orders(p_store_id uuid, p_status text DEFAULT 'active', p_limit integer DEFAULT 20, p_offset integer DEFAULT 0, p_user_id uuid DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path to 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_items json;
  v_total integer;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select m.role into v_role
  from public.store_members m
  where m.store_id = p_store_id and m.user_id = v_uid and m.status = 'active';
  if v_role is null then
    if (public.get_store_workbench_scope(p_store_id)->>'cross_store')::boolean then
      v_role := 'admin';
    elsif public._can_admin_store(p_store_id) then
      v_role := 'admin';
    else
      raise exception '你没有查看这家门店订单的权限' using errcode = '42501';
    end if;
  end if;

  select count(*) into v_total
  from public.orders o
  where o.store_id = p_store_id
    and o.payment_channel = 'offline_store'
    and (p_user_id is null or o.user_id = p_user_id)
    and (
      (p_status = 'active' and o.offline_status in ('awaiting_payment','awaiting_verification'))
      or (p_status = 'verified' and o.offline_status = 'verified'
          and (v_role <> 'clerk' or o.verified_by = v_uid))
      or (p_status = 'cancelled' and o.offline_status = 'cancelled'
          and (v_role <> 'clerk' or o.user_id = v_uid))
      or (p_status = 'all' and (v_role <> 'clerk' or o.verified_by = v_uid or o.user_id = v_uid))
    );

  select json_agg(t order by t.created_at desc) into v_items
  from (
    select o.id, o.out_trade_no, o.product_title_snapshot, o.cover_image_snapshot,
           o.unit_price_cents, o.quantity, o.total_amount_cents,
           o.contact_name,
           public.get_store_visible_phone(p_store_id, o.contact_phone) as contact_phone,
           o.remark,
           o.offline_status, o.offline_claimed_at, o.verified_at, o.created_at,
           o.requires_shipping_snapshot, o.user_id,
           vp.nickname as verified_by_nickname
    from public.orders o
    left join public.profiles vp on vp.id = o.verified_by
    where o.store_id = p_store_id
      and o.payment_channel = 'offline_store'
      and (p_user_id is null or o.user_id = p_user_id)
      and (
        (p_status = 'active' and o.offline_status in ('awaiting_payment','awaiting_verification'))
        or (p_status = 'verified' and o.offline_status = 'verified'
            and (v_role <> 'clerk' or o.verified_by = v_uid))
        or (p_status = 'cancelled' and o.offline_status = 'cancelled'
            and (v_role <> 'clerk' or o.user_id = v_uid))
        or (p_status = 'all' and (v_role <> 'clerk' or o.verified_by = v_uid or o.user_id = v_uid))
      )
    order by o.created_at desc
    limit greatest(least(p_limit, 100), 1)
    offset greatest(p_offset, 0)
  ) t;

  return json_build_object('items', coalesce(v_items, '[]'::json), 'total', v_total);
end;
$function$;

DROP FUNCTION IF EXISTS public.list_my_store_orders(uuid, text, integer, integer);

-- 授权收口：新 RPC 显式 REVOKE 后按需 GRANT；扩展签名重发 GRANT
REVOKE ALL ON FUNCTION public.list_enterprise_store_bindings(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_enterprise_store_bindings(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.transfer_store_customer(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.transfer_store_customer(uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.list_my_store_orders(uuid, text, integer, integer, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_my_store_orders(uuid, text, integer, integer, uuid) TO authenticated;