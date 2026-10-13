-- list_wecom_super_devices 增加 agent_goal / agent_redlines / agent_knowledge 字段
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
      'createdAt', d.created_at,
      'updatedAt', d.updated_at
    ) ORDER BY d.created_at DESC)
    FROM public.wecom_super_devices d
    LEFT JOIN public.profiles mp ON mp.id = d.bound_manager_id
    WHERE d.root_manager_id = v_root
  ), '[]'::jsonb);
END;
$function$;
