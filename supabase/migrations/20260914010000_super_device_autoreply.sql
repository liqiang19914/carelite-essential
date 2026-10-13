-- 企微超级助手：自动回复配置下沉到外挂账号 + 主人审批闭环 + 发送节流门
-- 1) 设备级自动回复配置（原商户级配置回填，跟随外挂账号走）
ALTER TABLE public.wecom_super_devices
  ADD COLUMN IF NOT EXISTS ar_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS ar_scene text NOT NULL DEFAULT 'private'
    CHECK (ar_scene IN ('private', 'private_group')),
  ADD COLUMN IF NOT EXISTS ar_start time NOT NULL DEFAULT '09:00',
  ADD COLUMN IF NOT EXISTS ar_end time NOT NULL DEFAULT '21:30',
  ADD COLUMN IF NOT EXISTS ar_min_score int NOT NULL DEFAULT 70,
  ADD COLUMN IF NOT EXISTS ar_cooldown_min int NOT NULL DEFAULT 10,
  ADD COLUMN IF NOT EXISTS ar_daily_cap int NOT NULL DEFAULT 50,
  ADD COLUMN IF NOT EXISTS ar_owner_userid text,
  ADD COLUMN IF NOT EXISTS ar_owner_name text;

COMMENT ON COLUMN public.wecom_super_devices.ar_enabled IS '该外挂账号是否开启客户消息自动回复';
COMMENT ON COLUMN public.wecom_super_devices.ar_owner_userid IS '主人微信外挂好友ID：转人工时向其发送审批请求，回复同意即代发';

-- 回填：从商户级配置迁移（仅开启且在生效设备列表中的设备）
UPDATE public.wecom_super_devices d SET
  ar_enabled = true,
  ar_scene = c.autoreply_scene,
  ar_start = c.autoreply_start,
  ar_end = c.autoreply_end,
  ar_min_score = c.autoreply_min_score,
  ar_cooldown_min = c.autoreply_cooldown_min,
  ar_daily_cap = c.autoreply_daily_cap,
  ar_owner_userid = c.autoreply_owner_userid,
  ar_owner_name = c.autoreply_owner_name
FROM public.wecom_super_merchant_config c
WHERE c.root_manager_id = d.root_manager_id
  AND COALESCE(c.autoreply_enabled, false) = true
  AND (
    c.autoreply_device_guids @> jsonb_build_array(d.guid)
    OR COALESCE((c.autoreply_device_guids #>> '{}')::jsonb @> jsonb_build_array(d.guid), false)
  );

-- 2) 队列新增 awaiting_owner（已向主人发出审批请求，等待主人定夺）
ALTER TABLE public.wecom_super_autoreply_queue
  DROP CONSTRAINT IF EXISTS wecom_super_arq_status_chk;
ALTER TABLE public.wecom_super_autoreply_queue
  ADD CONSTRAINT wecom_super_arq_status_chk CHECK (status IN
    ('pending', 'handling', 'replied', 'escalated', 'awaiting_owner', 'ignored', 'closed'));

-- 3) 主人审批请求表：一条转人工 = 一条待审批记录
CREATE TABLE IF NOT EXISTS public.wecom_super_reply_approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  device_guid text NOT NULL,
  queue_id uuid NOT NULL REFERENCES public.wecom_super_autoreply_queue(id) ON DELETE CASCADE,
  peer_id text NOT NULL,
  peer_type text NOT NULL CHECK (peer_type IN ('contact', 'room')),
  peer_name text,
  customer_msg text,
  reason text,
  suggested_reply text NOT NULL,
  owner_userid text NOT NULL,
  -- pending 待主人定夺 | used 已按主人指令发出 | cancelled 主人取消 | expired 过期
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'used', 'cancelled', 'expired')),
  reply_task_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT now() + interval '24 hours',
  resolved_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_wecom_super_appr_device
  ON public.wecom_super_reply_approvals (device_guid, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wecom_super_appr_root
  ON public.wecom_super_reply_approvals (root_manager_id);
CREATE INDEX IF NOT EXISTS idx_wecom_super_appr_queue
  ON public.wecom_super_reply_approvals (queue_id);

ALTER TABLE public.wecom_super_reply_approvals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.wecom_super_reply_approvals FROM PUBLIC;
REVOKE ALL ON public.wecom_super_reply_approvals FROM anon, authenticated;
GRANT ALL ON public.wecom_super_reply_approvals TO service_role;

-- 4) 全局发送节流门：多实例（分钟 cron + 消息即时触发）并发发送时，
--    以行锁预留时间槽的方式保证两条外发消息间隔不低于平台限速（防风控）。
CREATE TABLE IF NOT EXISTS public.wecom_super_send_gate (
  id int PRIMARY KEY DEFAULT 1,
  last_sent_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.wecom_super_send_gate (id, last_sent_at)
VALUES (1, now())
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.wecom_super_send_gate ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.wecom_super_send_gate FROM PUBLIC;
REVOKE ALL ON public.wecom_super_send_gate FROM anon, authenticated;
GRANT ALL ON public.wecom_super_send_gate TO service_role;

-- 5) list_wecom_super_devices RPC 增补自动回复字段
CREATE OR REPLACE FUNCTION public.list_wecom_super_devices()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', d.id,
      'guid', d.guid,
      'deviceName', d.device_name,
      'areaCode', d.area_code,
      'areaName', d.area_name,
      'status', d.status,
      'loginUserid', d.login_userid,
      'loginNickname', d.login_nickname,
      'loginCorpid', d.login_corpid,
      'loginCorpName', d.login_corp_name,
      'avatarUrl', d.avatar_url,
      'boundManagerId', d.bound_manager_id,
      'boundManagerName', mp.nickname,
      'lastEventAt', d.last_event_at,
      'lastError', d.last_error,
      'agentGoal', d.agent_goal,
      'agentRedlines', d.agent_redlines,
      'agentKnowledge', d.agent_knowledge,
      'agentGroupRole', d.agent_group_role,
      'knowledgeIndexId', d.knowledge_index_id,
      'knowledgeIndexStatus', d.knowledge_index_status,
      'arEnabled', d.ar_enabled,
      'arScene', d.ar_scene,
      'arStart', d.ar_start,
      'arEnd', d.ar_end,
      'arMinScore', d.ar_min_score,
      'arCooldownMin', d.ar_cooldown_min,
      'arDailyCap', d.ar_daily_cap,
      'arOwnerUserid', d.ar_owner_userid,
      'arOwnerName', d.ar_owner_name,
      'createdAt', d.created_at,
      'updatedAt', d.updated_at
    ) ORDER BY d.created_at DESC)
    FROM public.wecom_super_devices d
    LEFT JOIN public.profiles mp ON mp.id = d.bound_manager_id
    WHERE d.root_manager_id = v_root
  ), '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_devices() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_devices() TO authenticated;
