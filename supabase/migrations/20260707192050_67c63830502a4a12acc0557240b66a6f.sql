-- 微信支付平台证书缓存（小程序原生支付回调验签用），仅 service_role 可访问
CREATE TABLE public.wechat_pay_platform_certificates (
  serial_no text PRIMARY KEY,
  mch_id text NOT NULL,
  certificate_pem text NOT NULL,
  effective_time timestamptz,
  expire_time timestamptz NOT NULL,
  fetched_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.wechat_pay_platform_certificates IS '微信支付平台证书缓存，用于小程序原生支付回调签名验证；仅 service_role 访问，无 anon/authenticated 策略';

ALTER TABLE public.wechat_pay_platform_certificates ENABLE ROW LEVEL SECURITY;

CREATE INDEX idx_wechat_pay_certs_expire ON public.wechat_pay_platform_certificates (expire_time);

-- 小程序原生微信支付（JSAPI）预支付单状态跟踪，仅 service_role 访问，前端不直接读写
CREATE TABLE public.wechat_miniapp_pay_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL UNIQUE REFERENCES public.orders(id) ON DELETE CASCADE,
  out_trade_no text NOT NULL UNIQUE,
  user_id uuid NOT NULL REFERENCES public.profiles(id),
  appid text NOT NULL,
  mch_id text NOT NULL,
  openid text NOT NULL,
  prepay_id text NOT NULL,
  prepay_expires_at timestamptz NOT NULL,
  wechat_transaction_id text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'prepay_created' CHECK (status IN ('prepay_created', 'paid', 'closed', 'failed')),
  last_error text NOT NULL DEFAULT '',
  notify_event_id text NOT NULL DEFAULT '',
  notified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.wechat_miniapp_pay_orders IS '小程序原生微信支付（JSAPI）预支付单与回调状态跟踪；仅 service_role 访问，前端通过 orders 表读取结果';

ALTER TABLE public.wechat_miniapp_pay_orders ENABLE ROW LEVEL SECURITY;

CREATE INDEX idx_wechat_miniapp_pay_orders_user ON public.wechat_miniapp_pay_orders (user_id, created_at DESC);