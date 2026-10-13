-- 扫码登录会话：scene 本身就是一次性凭据，全部经云函数用 service_role 读写。
-- 前端只拿 scene 轮询，永不直连本表，因此启用 RLS 且不给任何 anon / authenticated 策略。
CREATE TABLE IF NOT EXISTS public.wechat_scan_sessions (
  scene text PRIMARY KEY,
  status text NOT NULL DEFAULT 'pending',
  channel text NOT NULL DEFAULT 'pc',
  invite_manager_id uuid,
  return_path text,
  openid text,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  error_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  scanned_at timestamptz,
  confirmed_at timestamptz,
  consumed_at timestamptz,
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '5 minutes'),
  CONSTRAINT wechat_scan_sessions_status_check
    CHECK (status IN ('pending', 'scanned', 'confirmed', 'consumed')),
  CONSTRAINT wechat_scan_sessions_channel_check
    CHECK (channel IN ('pc', 'mobile_browser'))
);

ALTER TABLE public.wechat_scan_sessions ENABLE ROW LEVEL SECURITY;

-- 清理过期会话时按 expires_at 扫，点查登录态时走主键
CREATE INDEX IF NOT EXISTS wechat_scan_sessions_expires_at_idx
  ON public.wechat_scan_sessions (expires_at);

-- 明确收回前端角色的表级权限，双重保险（RLS 无策略已拒，这里连表都拿不到）
REVOKE ALL ON public.wechat_scan_sessions FROM anon, authenticated;

COMMENT ON TABLE public.wechat_scan_sessions IS '微信扫码登录临时会话：scene 为一次性凭据，5 分钟过期，仅云函数可读写';
COMMENT ON COLUMN public.wechat_scan_sessions.status IS 'pending=待扫码 scanned=已扫码待授权 confirmed=已授权待取回 consumed=已消费';
COMMENT ON COLUMN public.wechat_scan_sessions.channel IS 'pc=电脑扫码 mobile_browser=手机浏览器唤起';