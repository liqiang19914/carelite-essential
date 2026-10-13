-- 企微超级助手：外挂账号独立知识库（百炼 RAG）
-- 1) 设备表加：百炼索引 ID/状态 + 群聊角色职责设定
ALTER TABLE public.wecom_super_devices
  ADD COLUMN IF NOT EXISTS knowledge_index_id text,
  ADD COLUMN IF NOT EXISTS knowledge_category_id text,
  ADD COLUMN IF NOT EXISTS knowledge_index_status text NOT NULL DEFAULT 'none'
    CHECK (knowledge_index_status IN ('none','building','ready','failed')),
  ADD COLUMN IF NOT EXISTS agent_group_role text;

COMMENT ON COLUMN public.wecom_super_devices.knowledge_index_id IS '阿里云百炼 RAG 索引 ID（每台外挂设备一个独立知识库）';
COMMENT ON COLUMN public.wecom_super_devices.knowledge_index_status IS 'none=未训练 building=训练中 ready=可用 failed=失败';
COMMENT ON COLUMN public.wecom_super_devices.agent_group_role IS '群聊角色/职责范围设定：AI 据此判断群消息是否属于自己职责范畴，属于才回复';

-- 2) 设备知识库文档表（结构与 manager_knowledge_documents V3 对齐）
CREATE TABLE IF NOT EXISTS public.wecom_super_knowledge_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL,
  device_guid text NOT NULL,
  title text NOT NULL,
  file_name text,
  storage_url text,
  storage_key text,
  file_size_bytes integer,
  mime_type text,
  external_file_id text,
  external_index_id text,
  status text NOT NULL DEFAULT 'uploading'
    CHECK (status IN ('uploading','indexing','ready','failed')),
  error_stage text,
  error_code text,
  error_message text,
  bailian_raw_status text,
  bailian_job_id text,
  last_polled_at timestamptz,
  poll_count integer NOT NULL DEFAULT 0,
  client_idem_key text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_wecom_super_kd_device
  ON public.wecom_super_knowledge_documents (device_guid, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wecom_super_kd_status
  ON public.wecom_super_knowledge_documents (device_guid, status);
CREATE UNIQUE INDEX IF NOT EXISTS uq_wecom_super_kd_idem
  ON public.wecom_super_knowledge_documents (device_guid, client_idem_key)
  WHERE client_idem_key IS NOT NULL;

DROP TRIGGER IF EXISTS wecom_super_kd_set_updated_at ON public.wecom_super_knowledge_documents;
CREATE TRIGGER wecom_super_kd_set_updated_at
  BEFORE UPDATE ON public.wecom_super_knowledge_documents
  FOR EACH ROW EXECUTE FUNCTION public.shop_set_updated_at();

ALTER TABLE public.wecom_super_knowledge_documents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.wecom_super_knowledge_documents FROM anon, authenticated;
GRANT ALL ON public.wecom_super_knowledge_documents TO service_role;

-- 3) list_wecom_super_devices RPC 增补字段
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
      'createdAt', d.created_at,
      'updatedAt', d.updated_at
    ) ORDER BY d.created_at DESC)
    FROM public.wecom_super_devices d
    LEFT JOIN public.profiles mp ON mp.id = d.bound_manager_id
    WHERE d.root_manager_id = v_root
  ), '[]'::jsonb);
END;
$function$;
