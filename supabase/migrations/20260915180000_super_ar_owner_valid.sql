-- list_wecom_super_devices 增补 arOwnerValid：
-- 已配置的「主人微信」必须仍是本外挂账号（设备）的好友，审批私信才能由本账号发出。
-- 历史数据存在跨设备选过主人（external_userid 只挂在其他设备联系人里）的情况，
-- 会导致保存自动回复配置时被 EF 校验整单 400 拦截、界面无显性提示。
-- 返回 NULL = 未配置主人；true/false = 已配置且是否仍为本设备好友。

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
      'arOwnerValid', CASE
        WHEN d.ar_owner_userid IS NULL THEN NULL
        ELSE
          -- ① 通讯录行挂在本设备下；② 本设备与该人有私聊消息（可送达的硬证据，
          -- 覆盖 contacts 每企业单行被最后同步设备覆盖、通讯录漏同步等情况）。
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
