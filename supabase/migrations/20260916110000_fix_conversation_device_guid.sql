-- 修复会话列表串号问题：同一个客户被多个外挂添加时，会话列表只显示一条，
-- 点开后消息按时间混在一起。根因是 DISTINCT ON 只按 peer_id 聚合，没带 device_guid。
-- 修复：DISTINCT ON (m.device_guid, m.peer_id) → 每个设备+客户组合独立会话。
DROP FUNCTION IF EXISTS public.list_wecom_super_conversations(text, text, integer, integer, text);

CREATE OR REPLACE FUNCTION public.list_wecom_super_conversations(
  p_keyword text DEFAULT NULL::text,
  p_peer_type text DEFAULT NULL::text,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 20,
  p_device_guid text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
  v_keyword text := NULLIF(btrim(COALESCE(p_keyword, '')), '');
  v_peer_type text := CASE btrim(COALESCE(p_peer_type, ''))
                        WHEN 'contact' THEN 'contact'
                        WHEN 'room' THEN 'room'
                        ELSE NULL END;
  v_guid text := NULLIF(btrim(COALESCE(p_device_guid, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
  v_offset int := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_total int;
  v_items jsonb;
BEGIN
  WITH latest AS (
    -- 🔑 关键：DISTINCT ON (device_guid, peer_id) 让每个设备+客户组合独立
    SELECT DISTINCT ON (m.device_guid, m.peer_id)
           m.peer_id, m.peer_type, m.direction, m.msg_type,
           m.content_text, m.room_id, m.from_id, m.sender_name,
           m.device_guid, m.msg_time, m.created_at
    FROM public.wecom_super_messages m
    WHERE m.root_manager_id = v_root
      AND (v_guid IS NULL OR m.device_guid = v_guid)
    ORDER BY m.device_guid, m.peer_id, m.msg_time DESC, m.created_at DESC
  )
  SELECT count(*) INTO v_total
  FROM latest l
  LEFT JOIN public.wecom_super_contacts c
    ON c.root_manager_id = v_root AND c.external_userid = l.peer_id AND l.peer_type = 'contact'
  LEFT JOIN public.wecom_super_user_profiles up
    ON up.root_manager_id = v_root AND up.user_id = l.peer_id AND l.peer_type = 'contact'
  LEFT JOIN public.wecom_super_rooms r
    ON r.root_manager_id = v_root AND r.room_id = l.peer_id AND l.peer_type = 'room'
  WHERE (v_peer_type IS NULL OR l.peer_type = v_peer_type)
    AND (v_keyword IS NULL
         OR COALESCE(c.remark_name, '') ILIKE '%' || v_keyword || '%'
         OR COALESCE(c.name, '') ILIKE '%' || v_keyword || '%'
         OR COALESCE(up.nickname, '') ILIKE '%' || v_keyword || '%'
         OR COALESCE(r.remark_name, '') ILIKE '%' || v_keyword || '%'
         OR COALESCE(r.name, '') ILIKE '%' || v_keyword || '%'
         OR l.peer_id ILIKE '%' || v_keyword || '%');

  WITH latest AS (
    SELECT DISTINCT ON (m.device_guid, m.peer_id)
           m.peer_id, m.peer_type, m.direction, m.msg_type,
           m.content_text, m.room_id, m.from_id, m.sender_name,
           m.device_guid, m.msg_time, m.created_at
    FROM public.wecom_super_messages m
    WHERE m.root_manager_id = v_root
      AND (v_guid IS NULL OR m.device_guid = v_guid)
    ORDER BY m.device_guid, m.peer_id, m.msg_time DESC, m.created_at DESC
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(row)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT l.peer_id AS "peerId", l.peer_type AS "peerType",
           CASE WHEN l.peer_type = 'room'
                THEN COALESCE(NULLIF(r.remark_name, ''), NULLIF(r.name, ''), l.peer_id)
                ELSE COALESCE(NULLIF(c.remark_name, ''), NULLIF(c.name, ''),
                              NULLIF(up.nickname, ''), l.peer_id)
           END AS "peerName",
           CASE WHEN l.peer_type = 'room' THEN r.avatar_url
                ELSE COALESCE(c.avatar_url, NULLIF(up.avatar_url, ''))
           END AS "avatarUrl",
           (l.peer_type = 'contact'
             AND l.peer_id <> ''
             AND (up.is_internal
                  OR (left(l.peer_id, 6) = left(d.login_userid, 6)
                      AND l.peer_id <> d.login_userid))) AS "peerIsCorp",
           l.direction, l.msg_type AS "msgType",
           l.content_text AS "lastContent", l.msg_time AS "msgTime",
           -- 🔑 messageCount 也只统计该设备下的消息数
           (SELECT count(*) FROM public.wecom_super_messages m2
             WHERE m2.root_manager_id = v_root AND m2.peer_id = l.peer_id
               AND m2.device_guid = l.device_guid
               AND (v_guid IS NULL OR m2.device_guid = v_guid)) AS "messageCount",
           l.device_guid AS "lastDeviceGuid",
           NULLIF(d.login_nickname, '') AS "deviceName",
           d.avatar_url AS "deviceAvatar",
           d.status AS "deviceStatus",
           COALESCE(CASE WHEN l.peer_type = 'room' THEN r.ai_reply_enabled
                         ELSE c.ai_reply_enabled END, true) AS "aiReplyEnabled",
           CASE WHEN l.peer_type = 'room' THEN NULLIF(r.intro, '')
                ELSE NULLIF(c.intro, '') END AS "intro"
    FROM latest l
    LEFT JOIN public.wecom_super_contacts c
      ON c.root_manager_id = v_root AND c.external_userid = l.peer_id AND l.peer_type = 'contact'
    LEFT JOIN public.wecom_super_user_profiles up
      ON up.root_manager_id = v_root AND up.user_id = l.peer_id AND l.peer_type = 'contact'
    LEFT JOIN public.wecom_super_rooms r
      ON r.root_manager_id = v_root AND r.room_id = l.peer_id AND l.peer_type = 'room'
    LEFT JOIN public.wecom_super_devices d
      ON d.root_manager_id = v_root AND d.guid = l.device_guid
    WHERE (v_peer_type IS NULL OR l.peer_type = v_peer_type)
      AND (v_keyword IS NULL
           OR COALESCE(c.remark_name, '') ILIKE '%' || v_keyword || '%'
           OR COALESCE(c.name, '') ILIKE '%' || v_keyword || '%'
           OR COALESCE(up.nickname, '') ILIKE '%' || v_keyword || '%'
           OR COALESCE(r.remark_name, '') ILIKE '%' || v_keyword || '%'
           OR COALESCE(r.name, '') ILIKE '%' || v_keyword || '%'
           OR l.peer_id ILIKE '%' || v_keyword || '%')
    ORDER BY l.msg_time DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;
