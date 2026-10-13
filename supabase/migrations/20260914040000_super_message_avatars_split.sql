-- P0 消息记录体验：私信/群聊会话分列表 + 微信式头像昵称
-- 1) list_wecom_super_conversations 增加 p_peer_type 过滤（contact/room），便于前端两个列表分开
-- 2) list_wecom_super_messages 补发送者头像/昵称兜底（群成员是好友时取好友资料）、
--    自己（设备账号）头像昵称、会话对象头像，供前端渲染微信式气泡
-- 背景：Qiwe 回调事件的群 id 是 17 位 JSON 数字（超 2^53），历史库已存在舍入失真，
--      根因修复在回调保真解析；本迁移只做读模型增强，不改动历史消息。

-- ───────────────────────── 会话列表（支持私信/群分开） ─────────────────────────
DROP FUNCTION IF EXISTS public.list_wecom_super_conversations(text, int, int);

CREATE OR REPLACE FUNCTION public.list_wecom_super_conversations(
  p_keyword text DEFAULT NULL,
  p_peer_type text DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
  v_keyword text := NULLIF(btrim(COALESCE(p_keyword, '')), '');
  v_peer_type text := CASE btrim(COALESCE(p_peer_type, ''))
                        WHEN 'contact' THEN 'contact'
                        WHEN 'room' THEN 'room'
                        ELSE NULL END;
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
  v_offset int := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_total int;
  v_items jsonb;
BEGIN
  WITH latest AS (
    SELECT DISTINCT ON (m.peer_id)
           m.peer_id, m.peer_type, m.direction, m.msg_type,
           m.content_text, m.room_id, m.from_id, m.sender_name,
           m.msg_time, m.created_at
    FROM public.wecom_super_messages m
    WHERE m.root_manager_id = v_root
    ORDER BY m.peer_id, m.msg_time DESC, m.created_at DESC
  )
  SELECT count(*) INTO v_total
  FROM latest l
  LEFT JOIN public.wecom_super_contacts c
    ON c.root_manager_id = v_root AND c.external_userid = l.peer_id AND l.peer_type = 'contact'
  LEFT JOIN public.wecom_super_rooms r
    ON r.root_manager_id = v_root AND r.room_id = l.peer_id AND l.peer_type = 'room'
  WHERE (v_peer_type IS NULL OR l.peer_type = v_peer_type)
    AND (v_keyword IS NULL
         OR COALESCE(c.name, '') ILIKE '%' || v_keyword || '%'
         OR COALESCE(r.name, '') ILIKE '%' || v_keyword || '%'
         OR l.peer_id ILIKE '%' || v_keyword || '%');

  WITH latest AS (
    SELECT DISTINCT ON (m.peer_id)
           m.peer_id, m.peer_type, m.direction, m.msg_type,
           m.content_text, m.room_id, m.from_id, m.sender_name,
           m.msg_time, m.created_at
    FROM public.wecom_super_messages m
    WHERE m.root_manager_id = v_root
    ORDER BY m.peer_id, m.msg_time DESC, m.created_at DESC
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(row)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT l.peer_id AS "peerId", l.peer_type AS "peerType",
           CASE WHEN l.peer_type = 'room' THEN COALESCE(NULLIF(r.name, ''), l.peer_id)
                ELSE COALESCE(NULLIF(c.name, ''), l.peer_id) END AS "peerName",
           CASE WHEN l.peer_type = 'room' THEN r.avatar_url ELSE c.avatar_url END AS "avatarUrl",
           l.direction, l.msg_type AS "msgType",
           l.content_text AS "lastContent", l.msg_time AS "msgTime",
           (SELECT count(*) FROM public.wecom_super_messages m2
             WHERE m2.root_manager_id = v_root AND m2.peer_id = l.peer_id) AS "messageCount"
    FROM latest l
    LEFT JOIN public.wecom_super_contacts c
      ON c.root_manager_id = v_root AND c.external_userid = l.peer_id AND l.peer_type = 'contact'
    LEFT JOIN public.wecom_super_rooms r
      ON r.root_manager_id = v_root AND r.room_id = l.peer_id AND l.peer_type = 'room'
    WHERE (v_peer_type IS NULL OR l.peer_type = v_peer_type)
      AND (v_keyword IS NULL
           OR COALESCE(c.name, '') ILIKE '%' || v_keyword || '%'
           OR COALESCE(r.name, '') ILIKE '%' || v_keyword || '%'
           OR l.peer_id ILIKE '%' || v_keyword || '%')
    ORDER BY l.msg_time DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_conversations(text, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_conversations(text, text, int, int) TO authenticated;

-- ───────────────────────── 会话内消息（带头像/昵称） ─────────────────────────
CREATE OR REPLACE FUNCTION public.list_wecom_super_messages(
  p_peer_id text,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
  v_peer text := NULLIF(btrim(COALESCE(p_peer_id, '')), '');
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
  WHERE m.root_manager_id = v_root AND m.peer_id = v_peer;

  SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row."msgTime" ASC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT m.id, m.direction, m.msg_type AS "msgType", m.peer_type AS "peerType",
           m.content_text AS "contentText",
           m.from_id AS "fromId", m.to_id AS "toId", m.room_id AS "roomId",
           -- 群消息发送者昵称：回调没带时用好友资料兜底（群成员恰为好友/内部联系人）
           COALESCE(NULLIF(m.sender_name, ''), NULLIF(sc.name, '')) AS "senderName",
           sc.avatar_url AS "senderAvatar",
           m.msg_server_id AS "msgServerId",
           m.task_id AS "taskId", m.msg_time AS "msgTime",
           -- 自己（消息所属设备账号）头像昵称；自己发的气泡右侧使用
           d.avatar_url AS "selfAvatar",
           NULLIF(d.login_nickname, '') AS "selfName",
           -- 会话对象头像（私信对方 / 群）
           CASE WHEN m.peer_type = 'room' THEN r.avatar_url ELSE c.avatar_url END AS "peerAvatar"
    FROM public.wecom_super_messages m
    LEFT JOIN public.wecom_super_contacts sc
      ON sc.root_manager_id = v_root AND sc.external_userid = m.from_id
    LEFT JOIN public.wecom_super_devices d
      ON d.root_manager_id = v_root AND d.guid = m.device_guid
    LEFT JOIN public.wecom_super_contacts c
      ON c.root_manager_id = v_root AND c.external_userid = m.peer_id AND m.peer_type = 'contact'
    LEFT JOIN public.wecom_super_rooms r
      ON r.root_manager_id = v_root AND r.room_id = m.peer_id AND m.peer_type = 'room'
    WHERE m.root_manager_id = v_root AND m.peer_id = v_peer
    ORDER BY m.msg_time DESC, m.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_messages(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_messages(text, int, int) TO authenticated;
