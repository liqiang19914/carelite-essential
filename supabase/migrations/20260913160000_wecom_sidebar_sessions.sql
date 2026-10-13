-- 企微聊天侧边栏 H5：OAuth 换发的不透明会话令牌（7 天、可吊销）
-- 仅 Edge Function（service_role）访问，前台无任何直连权限。
CREATE TABLE IF NOT EXISTS public.wecom_sidebar_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  profile_id uuid NOT NULL,
  wecom_userid text NOT NULL,
  token_hash text NOT NULL UNIQUE,
  user_agent text,
  last_used_at timestamptz,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_wecom_sidebar_sessions_root
  ON public.wecom_sidebar_sessions(root_manager_id);
CREATE INDEX IF NOT EXISTS idx_wecom_sidebar_sessions_expires
  ON public.wecom_sidebar_sessions(expires_at);

COMMENT ON TABLE public.wecom_sidebar_sessions IS
  '企微侧边栏 H5 登录会话：token 仅以 SHA-256 散列落库，7 天过期，可整体吊销';

ALTER TABLE public.wecom_sidebar_sessions ENABLE ROW LEVEL SECURITY;
-- 不建任何 RLS 策略：service_role 绕过 RLS，其他角色一律无权

-- jsapi / agent_config ticket 缓存（7200s，提前 5 分钟过期），避免侧边栏每次打开都打企微
ALTER TABLE public.merchant_wecom_settings
  ADD COLUMN IF NOT EXISTS sidebar_jsapi_ticket text,
  ADD COLUMN IF NOT EXISTS sidebar_jsapi_ticket_expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS sidebar_agent_ticket text,
  ADD COLUMN IF NOT EXISTS sidebar_agent_ticket_expires_at timestamptz;
