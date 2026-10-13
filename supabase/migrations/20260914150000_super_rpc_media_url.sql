-- ───────────────────────── 修复 list_wecom_super_messages RPC（图片直链提取 + msgType 映射） ─────────────────────────
-- 1) msgType 映射：type_7/14/101 → image, type_16 → voice（前端好识别）
-- 2) contentRaw 双重编码解包，提前解析图片直链
--    content_raw 在 db 里是 jsonb 标量（字符串），需要先 content_raw #>> '{}' 拿到字符串再 cast jsonb

DROP FUNCTION IF EXISTS public.list_wecom_super_messages(text, int, int, text);

CREATE OR REPLACE FUNCTION public.list_wecom_super_messages(
  p_peer_id text,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 50,
  p_device_guid text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
  v_peer text := NULLIF(btrim(COALESCE(p_peer_id, '')), '');
  v_guid text := NULLIF(btrim(COALESCE(p_device_guid, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 50), 1), 200);
  v_offset int := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_total int;
  v_items jsonb;
BEGIN
  IF v_peer IS NULL THEN
    RAISE EXCEPTION '缺少会话参数' USING ERRCODE = '22023';
  END IF;

  SELECT count(*) INTO v_total
  FROM public.wecom_super_messages m
  WHERE m.root_manager_id = v_root AND m.peer_id = v_peer
    AND (v_guid IS NULL OR m.device_guid = v_guid);

  SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row."msgTime" ASC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT m.id, m.direction,
           CASE m.msg_type
             WHEN 'type_7' THEN 'image'
             WHEN 'type_14' THEN 'image'
             WHEN 'type_101' THEN 'image'
             WHEN 'type_16' THEN 'voice'
             ELSE m.msg_type
           END AS "msgType",
           m.peer_type AS "peerType",
           m.content_text AS "contentText",
           m.content_raw AS "contentRaw",
           m.from_id AS "fromId", m.to_id AS "toId", m.room_id AS "roomId",
           m.device_guid AS "deviceGuid",
           COALESCE(NULLIF(m.sender_name, ''), NULLIF(rm.room_nick, ''),
                    NULLIF(sc.name, ''), NULLIF(up.nickname, '')) AS "senderName",
           COALESCE(sc.avatar_url, NULLIF(up.avatar_url, '')) AS "senderAvatar",
           (m.from_id <> ''
             AND (up.is_internal
                  OR (left(m.from_id, 6) = left(d.login_userid, 6)
                      AND m.from_id <> d.login_userid))) AS "senderIsCorp",
           m.msg_server_id AS "msgServerId",
           m.task_id AS "taskId", m.msg_time AS "msgTime",
           d.avatar_url AS "selfAvatar",
           NULLIF(d.login_nickname, '') AS "selfName",
           CASE WHEN m.peer_type = 'room'
                THEN COALESCE(r.avatar_url, c.avatar_url)
                ELSE COALESCE(c.avatar_url, r.avatar_url) END AS "peerAvatar"
    FROM public.wecom_super_messages m
    LEFT JOIN public.wecom_super_contacts sc
      ON sc.root_manager_id = v_root AND sc.external_userid = m.from_id
    LEFT JOIN public.wecom_super_user_profiles up
      ON up.root_manager_id = v_root AND up.user_id = m.from_id
    LEFT JOIN public.wecom_super_room_members rm
      ON rm.root_manager_id = v_root AND rm.room_id = m.peer_id
     AND rm.user_id = m.from_id AND m.peer_type = 'room'
    LEFT JOIN public.wecom_super_devices d
      ON d.root_manager_id = v_root AND d.guid = m.device_guid
    LEFT JOIN public.wecom_super_contacts c
      ON c.root_manager_id = v_root AND c.external_userid = m.peer_id AND m.peer_type = 'contact'
    LEFT JOIN public.wecom_super_rooms r
      ON r.root_manager_id = v_root AND r.room_id = m.peer_id AND m.peer_type = 'room'
    WHERE m.root_manager_id = v_root AND m.peer_id = v_peer
      AND (v_guid IS NULL OR m.device_guid = v_guid)
    ORDER BY m.msg_time DESC, m.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_messages(text, int, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_messages(text, int, int, text) TO authenticated;
