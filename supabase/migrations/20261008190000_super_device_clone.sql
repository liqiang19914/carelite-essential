-- 企微超级助手：云设备换机迁移
-- 场景：原外挂账号被封/二维码失效 → 解封后在新云设备扫码登录同一个微信号，
-- 需要把旧设备的自动回复、AI人设、知识库、绑定员工、待跟进任务 100% 复制到新设备。
-- 好友/群/聊天记录按 root_manager_id + 微信ID 存储，天然延续，无需迁移。

-- 1) 旧设备标记被哪台新设备替换（保留旧设备记录与历史，不删除）
ALTER TABLE public.wecom_super_devices
  ADD COLUMN IF NOT EXISTS replaced_by_guid text;

COMMENT ON COLUMN public.wecom_super_devices.replaced_by_guid IS
  '换机迁移：本设备已被该 guid 的新设备接管，设置/待办均已迁移';

-- 2) list RPC 增补字段，前端用于隐藏/提示已替换设备
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
      'knowledgeCategoryId', d.knowledge_category_id,
      'knowledgeIndexStatus', d.knowledge_index_status,
      'arEnabled', d.ar_enabled,
      'arScene', d.ar_scene,
      'arStart', d.ar_start,
      'arEnd', d.ar_end,
      'arMinScore', d.ar_min_score,
      'arCooldownMin', d.ar_cooldown_min,
      'arCooldownSec', d.ar_cooldown_sec,
      'arCrossObjectIntervalSec', d.ar_cross_object_interval_sec,
      'arDailyCap', d.ar_daily_cap,
      'arOwnerUserid', d.ar_owner_userid,
      'arOwnerName', d.ar_owner_name,
      'arImageReplyEnabled', d.ar_image_reply_enabled,
      'replacedByGuid', d.replaced_by_guid,
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
