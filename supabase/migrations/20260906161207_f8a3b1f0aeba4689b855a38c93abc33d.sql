-- 441/444 门店绑定模式（关联/独占）与门店管理员跨店查看设置
-- Query Design Plan:
--   Op1 商户设置 get/save：actor=企业成员(读)/企业超管(写)，owner=enterprise root(root_manager_id)，单行 upsert，无 anon
--   Op2 bind_user_to_store：actor=登录客户，owner=目标门店归属商户(root_manager_id)，读 bind_mode 分支
--   Op3 手机号可见性：actor=门店成员/企业管理员，owner=数据所属门店，纯角色口径（owner/admin 明文，clerk 脱敏）
--   Op4 可访问门店集：actor=门店成员，scope=成员角色×admin_cross_store_view

-- 1. 商户级门店绑定设置表：按企业根一行
CREATE TABLE IF NOT EXISTS public.merchant_store_binding_settings (
  root_manager_id uuid PRIMARY KEY REFERENCES public.managers(id) ON DELETE CASCADE,
  bind_mode text NOT NULL DEFAULT 'linked'
    CHECK (bind_mode IN ('linked','exclusive')),
  admin_cross_store_view boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

COMMENT ON TABLE public.merchant_store_binding_settings IS
  '商户级门店绑定模式与管理员跨店查看设置：root_manager_id 按企业根一行；bind_mode=linked 关联模式（已绑别家仅浏览）/exclusive 独占模式（不可自助换绑，需管理员转移）；admin_cross_store_view 开启后店主/管理员可在门店工作台切换本企业全部门店';
COMMENT ON COLUMN public.merchant_store_binding_settings.bind_mode IS
  '顾客已绑定其他门店时的行为：linked=仅浏览不换绑；exclusive=拒绝换绑需平台处理；无设置行=保持历史确认换绑';
COMMENT ON COLUMN public.merchant_store_binding_settings.admin_cross_store_view IS
  '店主/管理员跨店查看：true 时门店工作台可访问本企业全部门店（店员不受影响，仅本店且手机号脱敏）';

ALTER TABLE public.merchant_store_binding_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.merchant_store_binding_settings FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_store_binding_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.merchant_store_binding_settings TO service_role;

-- 2. 内部辅助：按企业根读绑定设置（无行返回默认值 linked/false）
CREATE OR REPLACE FUNCTION public.get_store_binding_settings(p_root_manager_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_row public.merchant_store_binding_settings%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM public.merchant_store_binding_settings
  WHERE root_manager_id = p_root_manager_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('bind_mode', 'linked', 'admin_cross_store_view', false);
  END IF;
  RETURN jsonb_build_object('bind_mode', v_row.bind_mode, 'admin_cross_store_view', v_row.admin_cross_store_view);
END;
$function$;

-- 3. 内部辅助：调用者在给定门店的 store_members 角色（owner/admin/clerk/NULL）
CREATE OR REPLACE FUNCTION public.get_store_member_role(p_store_id uuid)
RETURNS text
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT m.role
  FROM public.store_members m
  WHERE m.store_id = p_store_id AND m.user_id = auth.uid() AND m.status = 'active'
  LIMIT 1;
$function$;

-- 4. 内部辅助：调用者在给定门店的工作台作用域 {role, cross_store}
--    cross_store=true 表示调用者可按管理员口径访问该门店（企业管理员，或开启跨店的本企业 owner/admin 成员）
CREATE OR REPLACE FUNCTION public.get_store_workbench_scope(p_store_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_root uuid;
  v_store_root uuid;
  v_cross boolean;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('role', null::text, 'cross_store', false);
  END IF;
  v_role := public.get_store_member_role(p_store_id);
  IF v_role IS NOT NULL THEN
    RETURN jsonb_build_object('role', v_role, 'cross_store', false);
  END IF;
  SELECT s.root_manager_id INTO v_store_root FROM public.stores s WHERE s.id = p_store_id;
  IF v_store_root IS NULL THEN
    RETURN jsonb_build_object('role', null::text, 'cross_store', false);
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL OR v_root <> v_store_root THEN
    RETURN jsonb_build_object('role', null::text, 'cross_store', false);
  END IF;
  IF public.is_enterprise_admin(v_uid) THEN
    RETURN jsonb_build_object('role', null::text, 'cross_store', true);
  END IF;
  SELECT bs.admin_cross_store_view INTO v_cross
  FROM public.merchant_store_binding_settings bs
  WHERE bs.root_manager_id = v_root;
  IF coalesce(v_cross, false) AND EXISTS (
    SELECT 1 FROM public.store_members m
    WHERE m.user_id = v_uid AND m.status = 'active' AND m.role IN ('owner','admin')
  ) THEN
    RETURN jsonb_build_object('role', null::text, 'cross_store', true);
  END IF;
  RETURN jsonb_build_object('role', null::text, 'cross_store', false);
END;
$function$;

-- 5. 内部辅助：门店顾客/订单手机号可见口径（平台管理员、本店 owner/admin、跨店管理员明文；其余脱敏）
CREATE OR REPLACE FUNCTION public.get_store_visible_phone(p_store_id uuid, p_phone text)
RETURNS text
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_scope jsonb;
BEGIN
  IF v_uid IS NULL OR p_phone IS NULL THEN
    RETURN p_phone;
  END IF;
  IF public.is_admin(v_uid) THEN
    RETURN p_phone;
  END IF;
  v_role := public.get_store_member_role(p_store_id);
  IF v_role IN ('owner','admin') THEN
    RETURN p_phone;
  END IF;
  v_scope := public.get_store_workbench_scope(p_store_id);
  IF (v_scope->>'cross_store')::boolean THEN
    RETURN p_phone;
  END IF;
  IF length(regexp_replace(p_phone, '[^0-9]', '', 'g')) = 11 THEN
    RETURN substr(p_phone, 1, 3) || '****' || substr(p_phone, 8);
  END IF;
  RETURN p_phone;
END;
$function$;

-- 6. 商户设置读取 RPC（无行返回默认值）
CREATE OR REPLACE FUNCTION public.get_merchant_store_binding_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.is_active_enterprise_content_member(v_uid) THEN
    RAISE EXCEPTION '所属企业当前不可配置，请联系企业负责人或平台处理' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  RETURN public.get_store_binding_settings(v_root);
END;
$function$;

-- 7. 商户设置保存 RPC（仅企业超管）
CREATE OR REPLACE FUNCTION public.save_merchant_store_binding_settings(
  p_bind_mode text,
  p_admin_cross_store_view boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RAISE EXCEPTION '只有企业超级管理员可以修改门店绑定设置' USING ERRCODE = '42501';
  END IF;
  IF p_bind_mode IS NULL OR p_bind_mode NOT IN ('linked','exclusive') THEN
    RAISE EXCEPTION '无效的门店绑定模式' USING ERRCODE = '22023';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '未找到所属企业，无法保存设置' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.merchant_store_binding_settings
    (root_manager_id, bind_mode, admin_cross_store_view, updated_by, updated_at)
  VALUES (v_root, p_bind_mode, coalesce(p_admin_cross_store_view, false), v_uid, now())
  ON CONFLICT (root_manager_id) DO UPDATE
    SET bind_mode = EXCLUDED.bind_mode,
        admin_cross_store_view = EXCLUDED.admin_cross_store_view,
        updated_by = v_uid,
        updated_at = now();

  RETURN jsonb_build_object('success', true);
END;
$function$;

-- 8. 可访问门店集：管理员+开=本企业全部门店；管理员+关/店员=仅本人 member 店；企业管理员=全部门店
CREATE OR REPLACE FUNCTION public.list_my_accessible_stores()
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_cross boolean;
  v_items json;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);

  IF v_root IS NOT NULL AND public.is_enterprise_admin(v_uid) THEN
    SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
    FROM (
      SELECT s.id, s.short_code, s.name, s.phone, s.status, s.root_manager_id,
             s.receipt_qr_url, s.payment_merchant_no, s.created_source,
             s.address, s.storefront_image_url, s.disabled_at, s.created_at,
             COALESCE(public.get_store_member_role(s.id), 'admin') AS my_role
      FROM public.stores s
      WHERE s.root_manager_id = v_root
    ) t;
    RETURN json_build_object('items', COALESCE(v_items, '[]'::json));
  END IF;

  SELECT COALESCE(bs.admin_cross_store_view, false) INTO v_cross
  FROM public.merchant_store_binding_settings bs
  WHERE bs.root_manager_id = v_root;
  IF v_root IS NOT NULL AND v_cross AND EXISTS (
    SELECT 1 FROM public.store_members m
    WHERE m.user_id = v_uid AND m.status = 'active' AND m.role IN ('owner','admin')
  ) THEN
    SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
    FROM (
      SELECT s.id, s.short_code, s.name, s.phone, s.status, s.root_manager_id,
             s.receipt_qr_url, s.payment_merchant_no, s.created_source,
             s.address, s.storefront_image_url, s.disabled_at, s.created_at,
             COALESCE(public.get_store_member_role(s.id), 'clerk') AS my_role
      FROM public.stores s
      WHERE s.root_manager_id = v_root
    ) t;
    RETURN json_build_object('items', COALESCE(v_items, '[]'::json));
  END IF;

  SELECT json_agg(t ORDER BY t.created_at DESC) INTO v_items
  FROM (
    SELECT s.id, s.short_code, s.name, s.phone, s.status, s.root_manager_id,
           s.receipt_qr_url, s.payment_merchant_no, s.created_source,
           s.address, s.storefront_image_url, s.disabled_at, s.created_at,
           m.role AS my_role
    FROM public.store_members m
    JOIN public.stores s ON s.id = m.store_id
    WHERE m.user_id = v_uid AND m.status = 'active'
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::json));
END;
$function$;

-- 9. bind_user_to_store：已绑别家时按目标门店归属商户的绑定模式分支（对外签名不变）
CREATE OR REPLACE FUNCTION public.bind_user_to_store(p_store_id uuid, p_confirm boolean default false)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path to 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_store public.stores%rowtype;
  v_current record;
  v_mode text;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select * into v_store from public.stores where id = p_store_id;
  if not found then
    raise exception '门店不存在' using errcode = '22023';
  end if;
  if v_store.status <> 'active' then
    raise exception '这家门店已暂停营业' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('user_store_binding:' || v_uid::text));

  select b.store_id, s.name, s.address, s.phone, s.storefront_image_url
  into v_current
  from public.user_store_bindings b
  join public.stores s on s.id = b.store_id
  where b.user_id = v_uid and b.status = 'active'
  order by b.bound_at desc
  limit 1;

  if v_current.store_id is not null and v_current.store_id <> p_store_id then
    select bs.bind_mode into v_mode
    from public.merchant_store_binding_settings bs
    where bs.root_manager_id = v_store.root_manager_id;

    if v_mode = 'linked' then
      return json_build_object(
        'bound', false,
        'already', true,
        'mode', 'linked',
        'viewOnly', true,
        'current_store_name', v_current.name,
        'current', json_build_object(
          'store_id', v_current.store_id,
          'name', v_current.name,
          'address', v_current.address,
          'phone', v_current.phone,
          'storefront_image_url', v_current.storefront_image_url
        )
      );
    end if;
    if v_mode = 'exclusive' then
      return json_build_object(
        'bound', false,
        'already', true,
        'mode', 'exclusive',
        'locked', true,
        'current_store_name', v_current.name,
        'current', json_build_object(
          'store_id', v_current.store_id,
          'name', v_current.name,
          'address', v_current.address,
          'phone', v_current.phone,
          'storefront_image_url', v_current.storefront_image_url
        )
      );
    end if;

    if coalesce(p_confirm, false) = false then
      return json_build_object(
        'bound', false,
        'already', true,
        'current', json_build_object(
          'store_id', v_current.store_id,
          'name', v_current.name,
          'address', v_current.address,
          'phone', v_current.phone,
          'storefront_image_url', v_current.storefront_image_url
        )
      );
    end if;
    update public.user_store_bindings
       set status = 'unbound', updated_at = now()
     where user_id = v_uid and status = 'active';
  end if;

  insert into public.user_store_bindings (user_id, store_id, status, bound_at, last_visit_at, created_at)
  values (v_uid, p_store_id, 'active', now(), now(), now())
  on conflict (user_id, store_id)
  do update set status = 'active', last_visit_at = now(), updated_at = now();

  return json_build_object(
    'bound', true,
    'store', json_build_object(
      'store_id', p_store_id,
      'name', v_store.name,
      'address', v_store.address,
      'phone', v_store.phone,
      'storefront_image_url', v_store.storefront_image_url
    )
  );
end;
$function$;

-- 10. list_store_binding_customers：手机号按角色返回（管理员明文/店员脱敏），访问口径扩展跨店
CREATE OR REPLACE FUNCTION public.list_store_binding_customers(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path to 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_store public.stores%rowtype;
  v_items json;
  v_total integer;
begin
  if v_uid is null then
    raise exception '请先登录' using errcode = '42501';
  end if;
  select * into v_store from public.stores where id = p_store_id;
  if not found then
    raise exception '门店不存在' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.store_members m
    where m.store_id = p_store_id and m.user_id = v_uid and m.status = 'active'
  ) and not public._can_admin_store(p_store_id)
     and public.get_enterprise_root_manager_id(v_uid) is distinct from v_store.root_manager_id
     and not public.is_admin(v_uid)
     and not (public.get_store_workbench_scope(p_store_id)->>'cross_store')::boolean then
    raise exception '你没有查看这家门店顾客的权限' using errcode = '42501';
  end if;

  select count(*) into v_total
  from public.user_store_bindings b
  where b.store_id = p_store_id and b.status = 'active';

  select json_agg(t order by t.bound_at desc) into v_items
  from (
    select p.id as user_id, p.nickname, p.avatar_url,
           public.get_store_visible_phone(p_store_id, p.phone) as phone_visible,
           b.bound_at, b.last_visit_at
    from public.user_store_bindings b
    join public.profiles p on p.id = b.user_id
    where b.store_id = p_store_id and b.status = 'active'
  ) t;

  return json_build_object('items', coalesce(v_items, '[]'::json), 'total', v_total);
end;
$function$;

-- 11. list_my_store_orders：跨店作用域访问 + 手机号按角色
CREATE OR REPLACE FUNCTION public.list_my_store_orders(p_store_id uuid, p_status text default 'active', p_limit integer default 20, p_offset integer default 0)
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

-- 12. preview_offline_store_order_by_code：跨店作用域访问 + 手机号按角色
CREATE OR REPLACE FUNCTION public.preview_offline_store_order_by_code(p_code text, p_store_id uuid DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_no text := public.parse_store_order_code(btrim(coalesce(p_code, '')));
  v_order public.orders%ROWTYPE;
  v_is_member boolean;
  v_store_name text;
  v_scope uuid := p_store_id;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF v_no = '' THEN
    RAISE EXCEPTION '核销码不能为空' USING ERRCODE = '22023';
  END IF;

  IF v_no ~ '^[0-9]{6}$' THEN
    IF v_scope IS NULL THEN
      SELECT m.store_id INTO v_scope
        FROM public.store_members m
       WHERE m.user_id = v_uid AND m.status = 'active'
       ORDER BY m.created_at ASC
       LIMIT 1;
    END IF;
    IF v_scope IS NULL
       OR NOT (
         EXISTS (
           SELECT 1 FROM public.store_members m
            WHERE m.store_id = v_scope AND m.user_id = v_uid AND m.status = 'active'
         )
         OR public._can_admin_store(v_scope)
         OR (public.get_store_workbench_scope(v_scope)->>'cross_store')::boolean
       ) THEN
      RAISE EXCEPTION '你没有权限操作这家门店' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO v_order FROM public.orders
     WHERE verify_code = v_no
       AND store_id = v_scope
       AND payment_channel = 'offline_store';
    IF NOT FOUND THEN
      IF EXISTS (
        SELECT 1 FROM public.orders
         WHERE verify_code = v_no AND payment_channel = 'offline_store'
      ) THEN
        RAISE EXCEPTION '这不是本店订单' USING ERRCODE = '22023';
      ELSE
        RAISE EXCEPTION '核销码无效或已失效' USING ERRCODE = '22023';
      END IF;
    END IF;
  ELSE
    SELECT * INTO v_order FROM public.orders
     WHERE out_trade_no = v_no AND payment_channel = 'offline_store';
    IF NOT FOUND THEN
      RAISE EXCEPTION '没有找到这张核销码对应的订单' USING ERRCODE = '22023';
    END IF;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.store_members m
    WHERE m.store_id = v_order.store_id AND m.user_id = v_uid AND m.status = 'active'
  ) INTO v_is_member;
  IF NOT coalesce(v_is_member, false)
     AND NOT public._can_admin_store(v_order.store_id)
     AND NOT (public.get_store_workbench_scope(v_order.store_id)->>'cross_store')::boolean THEN
    RAISE EXCEPTION '这不是本店订单' USING ERRCODE = '22023';
  END IF;

  SELECT name INTO v_store_name FROM public.stores WHERE id = v_order.store_id;

  RETURN json_build_object(
    'order_id', v_order.id,
    'out_trade_no', v_order.out_trade_no,
    'product_title', v_order.product_title_snapshot,
    'cover_image_url', v_order.cover_image_snapshot,
    'quantity', v_order.quantity,
    'total_amount_cents', v_order.total_amount_cents,
    'contact_name', v_order.contact_name,
    'contact_phone', public.get_store_visible_phone(v_order.store_id, v_order.contact_phone),
    'remark', v_order.remark,
    'offline_status', v_order.offline_status,
    'store_name', coalesce(v_store_name, ''),
    'created_at', v_order.created_at
  );
END;
$function$;

-- 13. verify_offline_store_order_by_code：跨店作用域访问
CREATE OR REPLACE FUNCTION public.verify_offline_store_order_by_code(p_code text, p_store_id uuid DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_no text := public.parse_store_order_code(btrim(coalesce(p_code, '')));
  v_order public.orders%ROWTYPE;
  v_scope uuid := p_store_id;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '42501';
  END IF;
  IF v_no = '' THEN
    RAISE EXCEPTION '核销码不能为空' USING ERRCODE = '22023';
  END IF;

  IF v_no ~ '^[0-9]{6}$' THEN
    IF v_scope IS NULL THEN
      SELECT m.store_id INTO v_scope
        FROM public.store_members m
       WHERE m.user_id = v_uid AND m.status = 'active'
       ORDER BY m.created_at ASC
       LIMIT 1;
    END IF;
    IF v_scope IS NULL
       OR NOT (
         EXISTS (
           SELECT 1 FROM public.store_members m
            WHERE m.store_id = v_scope AND m.user_id = v_uid AND m.status = 'active'
         )
         OR public._can_admin_store(v_scope)
         OR (public.get_store_workbench_scope(v_scope)->>'cross_store')::boolean
       ) THEN
      RAISE EXCEPTION '你没有权限操作这家门店' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO v_order FROM public.orders
     WHERE verify_code = v_no
       AND store_id = v_scope
       AND payment_channel = 'offline_store'
     FOR UPDATE;
    IF NOT FOUND THEN
      IF EXISTS (
        SELECT 1 FROM public.orders
         WHERE verify_code = v_no AND payment_channel = 'offline_store'
      ) THEN
        RAISE EXCEPTION '这不是本店订单' USING ERRCODE = '22023';
      ELSE
        RAISE EXCEPTION '核销码无效或已失效' USING ERRCODE = '22023';
      END IF;
    END IF;
  ELSE
    SELECT * INTO v_order FROM public.orders
     WHERE out_trade_no = v_no AND payment_channel = 'offline_store'
     FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION '没有找到这张核销码对应的订单' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.store_members m
    JOIN public.stores s ON s.id = m.store_id
    WHERE s.id = v_order.store_id AND m.user_id = v_uid AND m.status = 'active'
      AND s.status = 'active'
  ) AND NOT public._can_admin_store(v_order.store_id)
    AND NOT (public.get_store_workbench_scope(v_order.store_id)->>'cross_store')::boolean THEN
    RAISE EXCEPTION '这不是本店订单' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.stores s
    WHERE s.id = v_order.store_id AND s.status = 'active'
  ) THEN
    RAISE EXCEPTION '这家门店已停业，不能核销' USING ERRCODE = '22023';
  END IF;

  IF v_order.offline_status = 'verified' THEN
    RETURN json_build_object('success', true, 'already', true);
  END IF;
  IF v_order.offline_status = 'cancelled' THEN
    RAISE EXCEPTION '订单已取消，无法核销' USING ERRCODE = '22023';
  END IF;
  IF v_order.offline_status IS DISTINCT FROM 'awaiting_verification' THEN
    RAISE EXCEPTION '客户还没有确认到店付款，暂时不能核销' USING ERRCODE = '22023';
  END IF;

  UPDATE public.orders
     SET offline_status = 'verified',
         status = 'paid',
         payment_method = 'offline',
         paid_at = now(),
         completed_at = now(),
         verified_by = v_uid,
         verified_at = now(),
         updated_at = now()
   WHERE id = v_order.id;

  RETURN json_build_object('success', true);
END;
$function$;

-- 14. get_store_sales_overview：跨店作用域访问
CREATE OR REPLACE FUNCTION public.get_store_sales_overview(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_customers integer;
  v_verified_count integer;
  v_verified_amount bigint;
  v_active_count integer;
  v_top json;
  v_by_member json;
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
      raise exception '你不是这家门店的成员' using errcode = '42501';
    end if;
  end if;

  select count(*) into v_customers
  from public.user_store_bindings b
  where b.store_id = p_store_id and b.status = 'active';

  if v_role = 'clerk' then
    select count(*) into v_verified_count
    from public.orders o
    where o.store_id = p_store_id and o.payment_channel = 'offline_store'
      and o.offline_status = 'verified' and o.verified_by = v_uid;
    select coalesce(sum(o.total_amount_cents), 0) into v_verified_amount
    from public.orders o
    where o.store_id = p_store_id and o.payment_channel = 'offline_store'
      and o.offline_status = 'verified' and o.verified_by = v_uid;
  else
    select count(*) into v_verified_count
    from public.orders o
    where o.store_id = p_store_id and o.payment_channel = 'offline_store'
      and o.offline_status = 'verified';
    select coalesce(sum(o.total_amount_cents), 0) into v_verified_amount
    from public.orders o
    where o.store_id = p_store_id and o.payment_channel = 'offline_store'
      and o.offline_status = 'verified';
  end if;

  select count(*) into v_active_count
  from public.orders o
  where o.store_id = p_store_id and o.payment_channel = 'offline_store'
    and o.offline_status in ('awaiting_payment','awaiting_verification');

  select coalesce(json_agg(t), '[]'::json) into v_top
  from (
    select o.product_title_snapshot as title, o.cover_image_snapshot as cover_image_url,
           count(*) as orders, coalesce(sum(o.quantity), 0) as quantity,
           coalesce(sum(o.total_amount_cents), 0) as amount_cents
    from public.orders o
    where o.store_id = p_store_id and o.payment_channel = 'offline_store'
      and o.offline_status = 'verified'
      and (v_role <> 'clerk' or o.verified_by = v_uid)
    group by o.product_title_snapshot, o.cover_image_snapshot
    order by amount_cents desc
    limit 5
  ) t;

  select coalesce(json_agg(t), '[]'::json) into v_by_member
  from (
    select m.user_id, p.nickname, m.role,
           count(distinct case when o.offline_status = 'verified' then o.id end) as verified_count,
           coalesce(sum(case when o.offline_status = 'verified' then o.total_amount_cents end), 0) as amount_cents
    from public.store_members m
    left join public.profiles p on p.id = m.user_id
    left join public.orders o on o.store_id = p_store_id and o.payment_channel = 'offline_store'
      and o.verified_by = m.user_id
    where m.store_id = p_store_id and m.status = 'active'
    group by m.user_id, p.nickname, m.role
    order by amount_cents desc
  ) t;

  return json_build_object(
    'my_role', v_role,
    'customer_count', v_customers,
    'verified_count', v_verified_count,
    'verified_amount_cents', v_verified_amount,
    'active_orders', v_active_count,
    'top_products', v_top,
    'by_member', v_by_member
  );
end;
$function$;

-- 15. list_store_members：跨店作用域只读访问（写操作仍限本店成员）
CREATE OR REPLACE FUNCTION public.list_store_members(p_store_id uuid)
RETURNS json
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_items json;
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
      raise exception '你没有查看这家门店成员的权限' using errcode = '42501';
    end if;
  end if;
  if v_role = 'clerk' then
    raise exception '只有店主或管理员才能查看门店成员' using errcode = '42501';
  end if;

  select json_agg(t order by t.created_at asc) into v_items
  from (
    select m.id, m.user_id, m.role, m.status, m.created_at,
           p.nickname, p.avatar_url, p.phone
    from public.store_members m
    join public.profiles p on p.id = m.user_id
    where m.store_id = p_store_id
  ) t;
  return json_build_object('items', coalesce(v_items, '[]'::json));
end;
$function$;

-- 授权收口：内部辅助不开放；设置 RPC 与可访问门店集仅 authenticated
REVOKE ALL ON FUNCTION public.get_store_binding_settings(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_store_member_role(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_store_workbench_scope(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_store_visible_phone(uuid, text) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.get_merchant_store_binding_settings() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_merchant_store_binding_settings() TO authenticated;
REVOKE ALL ON FUNCTION public.save_merchant_store_binding_settings(text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_merchant_store_binding_settings(text, boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.list_my_accessible_stores() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_my_accessible_stores() TO authenticated;

GRANT EXECUTE ON FUNCTION public.bind_user_to_store(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_store_binding_customers(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_store_orders(uuid, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.preview_offline_store_order_by_code(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_offline_store_order_by_code(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_store_sales_overview(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_store_members(uuid) TO authenticated;