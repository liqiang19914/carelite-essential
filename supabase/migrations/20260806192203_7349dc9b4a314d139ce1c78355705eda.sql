-- ============================================================================
-- 小程序支付桥接票据
--
-- 为什么不直接把 H5 的登录态传进小程序：OEM 小程序包是商户自己下载、可修改后再上传的，
-- 而 access_token 能读到健康档案等全部个人数据。所以只签发一张
-- 「10 分钟内、仅这一笔订单、仅用于发起支付」的最小权限票据。
-- 票据明文只在签发时返回一次，库里只存 sha256，泄库也换不出可用票据。
-- ============================================================================

CREATE TABLE public.wechat_miniapp_pay_bridge_tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash bytea NOT NULL UNIQUE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  prepared_at timestamptz,
  last_used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.wechat_miniapp_pay_bridge_tickets IS
  'H5 → 小程序原生支付页的一次性桥接票据。明文只返回一次，仅存 sha256；作用域严格限定为单笔订单的支付发起与查单。';

CREATE INDEX wechat_miniapp_pay_bridge_tickets_order_idx
  ON public.wechat_miniapp_pay_bridge_tickets (order_id, created_at DESC);
CREATE INDEX wechat_miniapp_pay_bridge_tickets_expiry_idx
  ON public.wechat_miniapp_pay_bridge_tickets (expires_at)
  WHERE revoked_at IS NULL;

ALTER TABLE public.wechat_miniapp_pay_bridge_tickets ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.wechat_miniapp_pay_bridge_tickets FROM PUBLIC;
REVOKE ALL ON public.wechat_miniapp_pay_bridge_tickets FROM anon;
REVOKE ALL ON public.wechat_miniapp_pay_bridge_tickets FROM authenticated;


-- ─── 签发票据：登录用户为自己的待付订单换一张短期票据 ────────────────────────
CREATE OR REPLACE FUNCTION public.create_wechat_miniapp_pay_bridge_ticket(
  p_out_trade_no text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_order record;
  v_token text;
  v_expires timestamptz := now() + interval '10 minutes';
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '42501';
  END IF;

  SELECT id, user_id, status INTO v_order
  FROM public.orders WHERE out_trade_no = p_out_trade_no;

  IF v_order IS NULL THEN
    RAISE EXCEPTION '订单不存在' USING ERRCODE = '22023';
  END IF;
  IF v_order.user_id <> v_caller THEN
    RAISE EXCEPTION '无权操作该订单' USING ERRCODE = '42501';
  END IF;
  IF v_order.status = 'paid' THEN
    RAISE EXCEPTION '订单已支付' USING ERRCODE = '22023';
  END IF;
  IF v_order.status <> 'pending' THEN
    RAISE EXCEPTION '订单状态不支持支付' USING ERRCODE = '22023';
  END IF;

  -- 同一订单只保留最新一张票据：用户重复点「去支付」时旧票据立刻失效
  UPDATE public.wechat_miniapp_pay_bridge_tickets
  SET revoked_at = now()
  WHERE order_id = v_order.id AND revoked_at IS NULL;

  -- 两段 uuid 拼成 256 位随机 token；用内建 CSPRNG，不依赖扩展
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');

  INSERT INTO public.wechat_miniapp_pay_bridge_tickets (token_hash, order_id, user_id, expires_at)
  VALUES (sha256(convert_to(v_token, 'utf8')), v_order.id, v_caller, v_expires);

  RETURN jsonb_build_object('token', v_token, 'expires_at', v_expires);
END;
$$;

REVOKE ALL ON FUNCTION public.create_wechat_miniapp_pay_bridge_ticket(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_wechat_miniapp_pay_bridge_ticket(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_wechat_miniapp_pay_bridge_ticket(text) TO authenticated;


-- ─── 兑换票据：仅 service_role（小程序支付 Edge Function）可调用 ─────────────
CREATE OR REPLACE FUNCTION public.resolve_wechat_miniapp_pay_bridge_ticket(
  p_token          text,
  p_out_trade_no   text,
  p_mark_prepared  boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_t record;
  v_order record;
BEGIN
  IF p_token IS NULL OR length(p_token) < 32 THEN
    RETURN jsonb_build_object('valid', false, 'reason', '支付凭据无效，请返回订单页重新发起支付');
  END IF;

  SELECT t.id, t.order_id, t.user_id, t.expires_at, t.revoked_at
  INTO v_t
  FROM public.wechat_miniapp_pay_bridge_tickets t
  WHERE t.token_hash = sha256(convert_to(p_token, 'utf8'))
  FOR UPDATE;

  IF v_t IS NULL THEN
    RETURN jsonb_build_object('valid', false, 'reason', '支付凭据无效，请返回订单页重新发起支付');
  END IF;
  IF v_t.revoked_at IS NOT NULL THEN
    RETURN jsonb_build_object('valid', false, 'reason', '支付凭据已失效，请返回订单页重新发起支付');
  END IF;
  IF v_t.expires_at <= now() THEN
    RETURN jsonb_build_object('valid', false, 'reason', '支付凭据已过期，请返回订单页重新发起支付');
  END IF;

  SELECT id, out_trade_no, user_id INTO v_order
  FROM public.orders WHERE id = v_t.order_id;

  IF v_order IS NULL THEN
    RETURN jsonb_build_object('valid', false, 'reason', '订单不存在');
  END IF;

  -- 票据严格绑定单笔订单：拿 A 单的票据去付 B 单一律拒绝
  IF p_out_trade_no IS NOT NULL AND v_order.out_trade_no <> p_out_trade_no THEN
    RETURN jsonb_build_object('valid', false, 'reason', '支付凭据与订单不匹配');
  END IF;

  UPDATE public.wechat_miniapp_pay_bridge_tickets
  SET last_used_at = now(),
      prepared_at  = CASE WHEN p_mark_prepared THEN coalesce(prepared_at, now()) ELSE prepared_at END
  WHERE id = v_t.id;

  RETURN jsonb_build_object(
    'valid', true,
    'order_id', v_order.id,
    'out_trade_no', v_order.out_trade_no,
    'user_id', v_order.user_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_wechat_miniapp_pay_bridge_ticket(text, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resolve_wechat_miniapp_pay_bridge_ticket(text, text, boolean) FROM anon;
REVOKE ALL ON FUNCTION public.resolve_wechat_miniapp_pay_bridge_ticket(text, text, boolean) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_wechat_miniapp_pay_bridge_ticket(text, text, boolean) TO service_role;