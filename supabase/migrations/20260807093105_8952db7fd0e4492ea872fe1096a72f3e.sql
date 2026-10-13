-- ============================================================================
-- 商城履约 + 积分体系 批次 3a：有效履约状态、收货地址簿、商户模块授权
-- ============================================================================

-- ─────────────────────────────────────────────────────────────
-- 3a-1) 有效履约状态：超过自动收货时间的「已发货」在所有读取路径都视为「已收货」。
--   本项目没有定时任务基建，因此「到期」是按 now() 派生的，而不是等某个任务来改数据。
--   落库只是顺带的收尾（在用户自己的列表 RPC 内有界执行），派生才是唯一真相。
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._effective_fulfillment_status(
  p_fulfillment_status text,
  p_auto_receive_at    timestamptz
)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_fulfillment_status = 'shipped'
         AND p_auto_receive_at IS NOT NULL
         AND p_auto_receive_at <= now()
      THEN 'received'
    ELSE p_fulfillment_status
  END;
$$;


-- ─────────────────────────────────────────────────────────────
-- 3a-2) 当前用户绑定的商户企业（根管理师）
--   绑定规则与前端一致：只认 role='manager' 的 active 绑定，
--   created_at 相同时用 id 兜底，保证每次解析出同一家。
--   员工绑定要上溯到企业主账号，因为模块授权是按企业发的。
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._my_bound_root_manager_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(mp.parent_manager_id, mp.id)
  FROM public.client_relations cr
  JOIN public.profiles mp ON mp.id = cr.manager_id AND mp.role = 'manager'
  WHERE cr.client_id = auth.uid()
    AND cr.status = 'active'
  ORDER BY cr.created_at DESC, cr.id DESC
  LIMIT 1;
$$;


-- ─────────────────────────────────────────────────────────────
-- 3a-3) 收货地址簿写入
--   全部经 RPC：唯一默认地址是数据库级不变量（部分唯一索引），
--   切换默认必须「先清后置」，中间态会撞索引，所以必须在同事务内
--   并按用户加事务级顾问锁串行化。
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.upsert_my_shipping_address(
  p_id             uuid    DEFAULT NULL,
  p_contact_name   text    DEFAULT '',
  p_contact_phone  text    DEFAULT '',
  p_province       text    DEFAULT '',
  p_city           text    DEFAULT '',
  p_district       text    DEFAULT '',
  p_address_detail text    DEFAULT '',
  p_is_default     boolean DEFAULT false
)
RETURNS public.user_shipping_addresses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_name   text;
  v_phone  text;
  v_prov   text;
  v_city   text;
  v_dist   text;
  v_addr   text;
  v_count  integer;
  v_makeDefault boolean;
  v_row    public.user_shipping_addresses;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  v_name  := btrim(COALESCE(p_contact_name, ''));
  v_phone := btrim(COALESCE(p_contact_phone, ''));
  v_prov  := btrim(COALESCE(p_province, ''));
  v_city  := btrim(COALESCE(p_city, ''));
  v_dist  := btrim(COALESCE(p_district, ''));
  v_addr  := btrim(COALESCE(p_address_detail, ''));

  IF v_name = '' OR char_length(v_name) > 50 THEN
    RAISE EXCEPTION '请填写收货人姓名（50 字以内）' USING ERRCODE = '22023';
  END IF;
  IF v_phone !~ '^1[3-9][0-9]{9}$' THEN
    RAISE EXCEPTION '请填写正确的 11 位手机号' USING ERRCODE = '22023';
  END IF;
  IF v_prov = '' OR v_city = '' OR v_dist = '' THEN
    RAISE EXCEPTION '请选择完整的省、市、区' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_prov) > 30 OR char_length(v_city) > 30 OR char_length(v_dist) > 30 THEN
    RAISE EXCEPTION '省市区名称过长' USING ERRCODE = '22023';
  END IF;
  IF v_addr = '' OR char_length(v_addr) > 200 THEN
    RAISE EXCEPTION '请填写详细地址（200 字以内）' USING ERRCODE = '22023';
  END IF;

  -- 同一用户的默认地址切换必须串行化，否则并发保存会撞唯一索引
  PERFORM pg_advisory_xact_lock(hashtextextended('usa_default:' || v_uid::text, 0));

  SELECT count(*) INTO v_count
  FROM public.user_shipping_addresses WHERE user_id = v_uid;

  -- 第一条地址自动成为默认，避免用户建完地址却没有默认可选
  v_makeDefault := COALESCE(p_is_default, false) OR v_count = 0;

  IF p_id IS NULL THEN
    IF v_count >= 20 THEN
      RAISE EXCEPTION '最多保存 20 个收货地址，请先删除不用的地址' USING ERRCODE = '22023';
    END IF;
  ELSE
    IF NOT EXISTS (
      SELECT 1 FROM public.user_shipping_addresses WHERE id = p_id AND user_id = v_uid
    ) THEN
      RAISE EXCEPTION '收货地址不存在' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_makeDefault THEN
    UPDATE public.user_shipping_addresses
    SET is_default = false, updated_at = now()
    WHERE user_id = v_uid AND is_default = true
      AND (p_id IS NULL OR id <> p_id);
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.user_shipping_addresses (
      user_id, contact_name, contact_phone, province, city, district,
      address_detail, is_default
    ) VALUES (
      v_uid, v_name, v_phone, v_prov, v_city, v_dist, v_addr, v_makeDefault
    )
    RETURNING * INTO v_row;
  ELSE
    UPDATE public.user_shipping_addresses
    SET contact_name   = v_name,
        contact_phone  = v_phone,
        province       = v_prov,
        city           = v_city,
        district       = v_dist,
        address_detail = v_addr,
        is_default     = v_makeDefault OR is_default,
        updated_at     = now()
    WHERE id = p_id AND user_id = v_uid
    RETURNING * INTO v_row;
  END IF;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_my_shipping_address(uuid, text, text, text, text, text, text, boolean) TO authenticated;


CREATE OR REPLACE FUNCTION public.set_my_default_shipping_address(p_id uuid)
RETURNS public.user_shipping_addresses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.user_shipping_addresses;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('usa_default:' || v_uid::text, 0));

  IF NOT EXISTS (
    SELECT 1 FROM public.user_shipping_addresses WHERE id = p_id AND user_id = v_uid
  ) THEN
    RAISE EXCEPTION '收货地址不存在' USING ERRCODE = '22023';
  END IF;

  UPDATE public.user_shipping_addresses
  SET is_default = false, updated_at = now()
  WHERE user_id = v_uid AND is_default = true AND id <> p_id;

  UPDATE public.user_shipping_addresses
  SET is_default = true, updated_at = now()
  WHERE id = p_id AND user_id = v_uid
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_my_default_shipping_address(uuid) TO authenticated;


CREATE OR REPLACE FUNCTION public.delete_my_shipping_address(p_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid        uuid := auth.uid();
  v_was_default boolean;
  v_next        uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('usa_default:' || v_uid::text, 0));

  SELECT is_default INTO v_was_default
  FROM public.user_shipping_addresses
  WHERE id = p_id AND user_id = v_uid;

  IF v_was_default IS NULL THEN
    RAISE EXCEPTION '收货地址不存在' USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.user_shipping_addresses WHERE id = p_id AND user_id = v_uid;

  -- 删掉的是默认地址时，把最近新建的一条顶上来，避免结算页没有默认地址可用
  IF v_was_default THEN
    SELECT id INTO v_next
    FROM public.user_shipping_addresses
    WHERE user_id = v_uid
    ORDER BY created_at DESC, id DESC
    LIMIT 1;

    IF v_next IS NOT NULL THEN
      UPDATE public.user_shipping_addresses
      SET is_default = true, updated_at = now()
      WHERE id = v_next;
    END IF;
  END IF;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_my_shipping_address(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────
-- 3a-4) 商户模块授权
--   两级：平台授予 grant_status，商户自开关 is_enabled，二者同时成立才开放。
--   只有「积分兑换」参与 C 端开放判断；订单履约是实体商品的基础能力，
--   不做开关，否则商户忘记开启就会造成订单永远无法发货收货。
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_set_merchant_module_grant(
  p_manager_id uuid,
  p_module_key text,
  p_granted    boolean,
  p_notes      text DEFAULT NULL
)
RETURNS public.merchant_module_grants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.merchant_module_grants;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '只有平台管理员可以调整商户模块授权' USING ERRCODE = '42501';
  END IF;
  IF p_module_key NOT IN ('shop_order_lifecycle', 'points_exchange') THEN
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
      -- 回收授权时同时关掉商户开关，避免回收后 C 端仍然开放
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
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_merchant_module_grant(uuid, text, boolean, text) TO authenticated;


CREATE OR REPLACE FUNCTION public.set_my_merchant_module_enabled(
  p_module_key text,
  p_enabled    boolean
)
RETURNS public.merchant_module_grants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_root uuid := public._my_root_manager_id();
  v_row  public.merchant_module_grants;
BEGIN
  IF v_root IS NULL THEN
    RAISE EXCEPTION '只有商户账号可以设置商城模块' USING ERRCODE = '42501';
  END IF;
  IF p_module_key NOT IN ('shop_order_lifecycle', 'points_exchange') THEN
    RAISE EXCEPTION '未知的模块' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_module_grants
  WHERE manager_id = v_root AND module_key = p_module_key
  FOR UPDATE;

  IF v_row.id IS NULL OR v_row.grant_status <> 'granted' THEN
    RAISE EXCEPTION '平台尚未为你开放该模块，请联系平台运营' USING ERRCODE = '42501';
  END IF;

  UPDATE public.merchant_module_grants
  SET is_enabled = COALESCE(p_enabled, false), updated_at = now()
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_my_merchant_module_enabled(text, boolean) TO authenticated;


-- C 端：当前用户可见的商城模块开放状态
CREATE OR REPLACE FUNCTION public.get_my_shop_modules()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_root   uuid;
  v_points boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  v_root := public._my_bound_root_manager_id();

  -- 未绑定商户的平台直客：积分兑换默认开放
  IF v_root IS NULL THEN
    RETURN jsonb_build_object('points_exchange', true);
  END IF;

  SELECT (g.grant_status = 'granted' AND g.is_enabled) INTO v_points
  FROM public.merchant_module_grants g
  WHERE g.manager_id = v_root AND g.module_key = 'points_exchange';

  RETURN jsonb_build_object('points_exchange', COALESCE(v_points, false));
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_shop_modules() TO authenticated;