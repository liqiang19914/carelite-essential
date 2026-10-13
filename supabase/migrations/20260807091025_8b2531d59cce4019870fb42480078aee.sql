-- ============================================================================
-- 商城履约 + 积分体系 批次 1a：商品销售模式、SKU 积分价、订单履约与积分列
--
-- 关键约束：不改动 orders.status 的取值集合（pending/paid/cancelled/closed/
-- refunding/refunded），履约生命周期走独立的 fulfillment_status 列，
-- 以免影响已上线且已加固的微信支付 / 退款状态机。
-- ============================================================================

-- ─────────────────────────────────────────────────────────────
-- 一、products.sale_mode：正价现金商品 vs 积分兑换商品
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS sale_mode text NOT NULL DEFAULT 'cash';

ALTER TABLE public.products DROP CONSTRAINT IF EXISTS products_sale_mode_check;
ALTER TABLE public.products
  ADD CONSTRAINT products_sale_mode_check
  CHECK (sale_mode IN ('cash', 'points'));

-- 阶段一：积分兑换只允许平台自营商品，商户私域商品不得设为积分兑换
-- （商户没有平台积分的发行权，避免商户自行定价消耗平台积分）
ALTER TABLE public.products DROP CONSTRAINT IF EXISTS products_points_platform_only_check;
ALTER TABLE public.products
  ADD CONSTRAINT products_points_platform_only_check
  CHECK (sale_mode = 'cash' OR source_type = 'platform');

COMMENT ON COLUMN public.products.sale_mode IS
  'cash=正价现金商品；points=积分兑换商品。阶段一积分兑换仅限 source_type=platform。';


-- ─────────────────────────────────────────────────────────────
-- 二、product_skus.points_price：积分价（仅 sale_mode=points 时有意义）
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.product_skus
  ADD COLUMN IF NOT EXISTS points_price integer NOT NULL DEFAULT 0;

ALTER TABLE public.product_skus DROP CONSTRAINT IF EXISTS product_skus_points_price_check;
ALTER TABLE public.product_skus
  ADD CONSTRAINT product_skus_points_price_check
  CHECK (points_price >= 0);

COMMENT ON COLUMN public.product_skus.points_price IS
  '兑换所需积分数。仅当所属商品 sale_mode=points 时使用，下单 RPC 会校验其 > 0。';


-- ─────────────────────────────────────────────────────────────
-- 三、orders：履约生命周期 + 物流 + 积分支付
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS fulfillment_status text NOT NULL DEFAULT 'not_required',
  ADD COLUMN IF NOT EXISTS fulfillment_manager_id_snapshot uuid,
  ADD COLUMN IF NOT EXISTS carrier_name text,
  ADD COLUMN IF NOT EXISTS tracking_no text,
  ADD COLUMN IF NOT EXISTS shipped_at timestamptz,
  ADD COLUMN IF NOT EXISTS auto_receive_at timestamptz,
  ADD COLUMN IF NOT EXISTS received_at timestamptz,
  ADD COLUMN IF NOT EXISTS completed_at timestamptz,
  ADD COLUMN IF NOT EXISTS pay_mode text NOT NULL DEFAULT 'cash',
  ADD COLUMN IF NOT EXISTS unit_points integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS points_amount integer NOT NULL DEFAULT 0;

-- 回填存量：虚拟商品无需履约；实体商品进入待发货
-- （待发货标签同时要求 status='paid'，所以未付款的实体单标成 pending_ship 不会误显示）
UPDATE public.orders
SET fulfillment_status = CASE
      WHEN requires_shipping_snapshot IS DISTINCT FROM true THEN 'not_required'
      ELSE 'pending_ship'
    END
WHERE fulfillment_status = 'not_required';

ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_fulfillment_status_check;
ALTER TABLE public.orders
  ADD CONSTRAINT orders_fulfillment_status_check
  CHECK (fulfillment_status IN ('not_required', 'pending_ship', 'shipped', 'received', 'completed'));

ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_pay_mode_check;
ALTER TABLE public.orders
  ADD CONSTRAINT orders_pay_mode_check
  CHECK (pay_mode IN ('cash', 'points'));

-- 形状约束：现金单不得携带积分金额；积分单不得携带任何现金金额，
-- 且积分总额必须等于单价积分 × 数量（防止客户端或未来代码写出不一致的单）
ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_pay_mode_shape_check;
ALTER TABLE public.orders
  ADD CONSTRAINT orders_pay_mode_shape_check
  CHECK (
    (
      pay_mode = 'cash'
      AND unit_points = 0
      AND points_amount = 0
    )
    OR (
      pay_mode = 'points'
      AND unit_price_cents = 0
      AND total_amount_cents = 0
      AND COALESCE(paid_amount_cents, 0) = 0
      AND unit_points > 0
      AND points_amount = unit_points * quantity
    )
  );

-- 虚拟商品（无需发货）永远不进入履约流程
ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_virtual_fulfillment_check;
ALTER TABLE public.orders
  ADD CONSTRAINT orders_virtual_fulfillment_check
  CHECK (
    requires_shipping_snapshot = true
    OR fulfillment_status = 'not_required'
  );

-- 一旦进入已发货及之后的状态，物流公司 / 单号 / 发货时间 / 自动收货时间必须齐备。
-- auto_receive_at 是「超时自动确认收货」的唯一依据（本项目没有定时任务基建，
-- 收货到期由各读取路径按 now() 派生 + 用户自己的列表 RPC 有界落库），
-- 因此它缺失就等于该单永远无法自动收货，必须在此强制。
ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_shipping_info_check;
ALTER TABLE public.orders
  ADD CONSTRAINT orders_shipping_info_check
  CHECK (
    fulfillment_status NOT IN ('shipped', 'received', 'completed')
    OR (
      carrier_name IS NOT NULL AND btrim(carrier_name) <> ''
      AND tracking_no IS NOT NULL AND btrim(tracking_no) <> ''
      AND shipped_at IS NOT NULL
      AND auto_receive_at IS NOT NULL
    )
  );

-- 收货 / 完成时间与状态保持一致
ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_received_at_check;
ALTER TABLE public.orders
  ADD CONSTRAINT orders_received_at_check
  CHECK (
    fulfillment_status NOT IN ('received', 'completed')
    OR received_at IS NOT NULL
  );

COMMENT ON COLUMN public.orders.fulfillment_status IS
  '履约状态，与支付状态 status 完全解耦：not_required(虚拟商品) / pending_ship / shipped / received / completed。';
COMMENT ON COLUMN public.orders.auto_receive_at IS
  '发货时按后台配置天数写入的自动确认收货时刻。到期后所有读取路径都视为已收货；用户自己的订单列表 RPC 会顺带把本人已过期的行落库。';
COMMENT ON COLUMN public.orders.pay_mode IS
  'cash=现金支付单（走支付网关）；points=积分兑换单（不进任何支付与退款流程）。';
COMMENT ON COLUMN public.orders.fulfillment_manager_id_snapshot IS
  '实际负责发货的商户快照。平台自营单为 NULL，由平台后台发货。';


-- ─────────────────────────────────────────────────────────────
-- 四、索引：覆盖用户端六标签查询、商户履约筛选、自动收货扫描
-- ─────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_orders_user_status_fulfillment_created
  ON public.orders (user_id, status, fulfillment_status, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_orders_auto_receive_due
  ON public.orders (auto_receive_at)
  WHERE fulfillment_status = 'shipped' AND auto_receive_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_orders_points_mode
  ON public.orders (user_id, created_at DESC)
  WHERE pay_mode = 'points';

CREATE INDEX IF NOT EXISTS idx_orders_owner_fulfillment_created
  ON public.orders (owner_manager_id_snapshot, fulfillment_status, created_at DESC, id DESC)
  WHERE owner_manager_id_snapshot IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_products_sale_mode_status
  ON public.products (sale_mode, status, is_featured DESC, sort_weight DESC)
  WHERE (status)::text = 'active';