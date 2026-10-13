-- ============================================================================
-- 企微超级助手 RAG 自动回复打通：好友映射表 + 设备知识库字段
-- 1) wecom_super_contact_mapping：外挂好友 ↔ 企微平台客户档案映射
--    （super 侧 userId 是纯数字，pro 侧 external_userid 是 wm... 格式，
--     无共同 ID，需通过昵称匹配 + 人工确认建立映射）
-- 2) wecom_super_devices 增加 agent_goal / agent_redlines / agent_knowledge
-- ============================================================================

-- 1. 好友映射表 -------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.wecom_super_contact_mapping (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id       uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  super_device_guid     text NOT NULL,
  super_external_userid text NOT NULL,
  pro_external_userid   text NOT NULL,
  pro_name              text,
  matched_by            text NOT NULL DEFAULT 'manual'
                          CHECK (matched_by IN ('auto', 'manual')),
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

-- 同一外挂好友只能映射一个平台客户
CREATE UNIQUE INDEX IF NOT EXISTS uq_super_contact_mapping_peer
  ON public.wecom_super_contact_mapping (super_device_guid, super_external_userid);

-- 反查：平台客户映射到哪些外挂好友
CREATE INDEX IF NOT EXISTS idx_super_contact_mapping_pro
  ON public.wecom_super_contact_mapping (root_manager_id, pro_external_userid);

ALTER TABLE public.wecom_super_contact_mapping ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.wecom_super_contact_mapping FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.wecom_super_contact_mapping TO service_role;

-- 2. 设备知识库字段 ---------------------------------------------------------
ALTER TABLE public.wecom_super_devices
  ADD COLUMN IF NOT EXISTS agent_goal       text,
  ADD COLUMN IF NOT EXISTS agent_redlines   text,
  ADD COLUMN IF NOT EXISTS agent_knowledge  text;
