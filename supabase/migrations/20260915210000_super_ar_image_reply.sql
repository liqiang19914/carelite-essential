-- AI 自动回复支持「配图回复」：设备级开关，默认关闭。
-- 开启后 AI 决策可输出画图指令（imagePrompt），文字照常先发，
-- 图片经通义万相生成后作为独立任务补发，生成失败不影响文字回复。

ALTER TABLE public.wecom_super_devices
  ADD COLUMN IF NOT EXISTS ar_image_reply_enabled boolean NOT NULL DEFAULT false;

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
      'arImageReplyEnabled', d.ar_image_reply_enabled,
      'arOwnerUserid', d.ar_owner_userid,
      'arOwnerName', d.ar_owner_name,
      'arOwnerValid', CASE
        WHEN d.ar_owner_userid IS NULL THEN NULL
        ELSE
          EXISTS (
            SELECT 1 FROM public.wecom_super_contacts c
            WHERE c.root_manager_id = d.root_manager_id
              AND c.device_guid = d.guid
              AND c.external_userid = d.ar_owner_userid
          )
          OR EXISTS (
            SELECT 1 FROM public.wecom_super_messages m
            WHERE m.device_guid = d.guid
              AND m.room_id IS NULL
              AND m.peer_type = 'contact'
              AND m.peer_id = d.ar_owner_userid
          )
      END,
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
