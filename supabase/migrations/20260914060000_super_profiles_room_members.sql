-- 企微超级助手：资料补全 + 历史修复
-- 1) wecom_super_user_profiles：同事（getWxWorkContactList）与群成员（batchGetUserinfo，
--    支持非好友）的统一资料缓存。contacts 表仅存外部好友，避免污染好友列表 UI。
-- 2) wecom_super_room_members：群成员本群昵称（/room/batchGetRoomDetail）。
-- 3) list_wecom_super_messages / list_wecom_super_conversations 接入资料兜底链：
--    发送者昵称 = 回调 sender_name → 本群昵称 → 好友名 → 资料库昵称
--    发送者头像 = 好友头像 → 资料库头像
--    企业微信同事 = 号段规则 OR 资料库 is_internal

-- ───────────────────────── 1. 用户资料 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.wecom_super_user_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  user_id text NOT NULL,                                   -- Qiwe 侧 userId（好友/同事/群成员通用）
  nickname text NOT NULL DEFAULT '',                       -- 昵称（企微优先取 nickname，缺省 realName）
  avatar_url text NOT NULL DEFAULT '',
  is_internal boolean NOT NULL DEFAULT false,              -- 企业微信内部成员（同事）
  synced_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_super_user_profile UNIQUE (root_manager_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_wecom_super_user_profiles_root
  ON public.wecom_super_user_profiles (root_manager_id);

ALTER TABLE public.wecom_super_user_profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.wecom_super_user_profiles FROM anon, authenticated;

-- ───────────────────────── 2. 群成员 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.wecom_super_room_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  room_id text NOT NULL,
  user_id text NOT NULL,
  room_nick text NOT NULL DEFAULT '',                      -- 本群昵称（群内显示名）
  is_admin boolean NOT NULL DEFAULT false,
  synced_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_super_room_member UNIQUE (root_manager_id, room_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_wecom_super_room_members_room
  ON public.wecom_super_room_members (root_manager_id, room_id);

ALTER TABLE public.wecom_super_room_members ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.wecom_super_room_members FROM anon, authenticated;

-- ───────────────────────── 3. 消息 RPC 接入资料兜底链 ─────────────────────────
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
           -- 群消息发送者昵称：回调没带时 本群昵称 → 好友名 → 资料库昵称 逐级兜底
           COALESCE(NULLIF(m.sender_name, ''), NULLIF(rm.room_nick, ''),
                    NULLIF(sc.name, ''), NULLIF(up.nickname, '')) AS "senderName",
           COALESCE(sc.avatar_url, NULLIF(up.avatar_url, '')) AS "senderAvatar",
           -- 企业微信同事：与设备账号同企业号段（排除设备自身）或资料库标记
           (m.from_id <> ''
             AND (up.is_internal
                  OR (left(m.from_id, 6) = left(d.login_userid, 6)
                      AND m.from_id <> d.login_userid))) AS "senderIsCorp",
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
    ORDER BY m.msg_time DESC, m.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_messages(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_messages(text, int, int) TO authenticated;

-- ───────────────────────── 4. 会话 RPC：同事私信真名/头像兜底 ─────────────────────────
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
           m.device_guid, m.msg_time, m.created_at
    FROM public.wecom_super_messages m
    WHERE m.root_manager_id = v_root
    ORDER BY m.peer_id, m.msg_time DESC, m.created_at DESC
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
         OR COALESCE(c.name, '') ILIKE '%' || v_keyword || '%'
         OR COALESCE(up.nickname, '') ILIKE '%' || v_keyword || '%'
         OR COALESCE(r.name, '') ILIKE '%' || v_keyword || '%'
         OR l.peer_id ILIKE '%' || v_keyword || '%');

  WITH latest AS (
    SELECT DISTINCT ON (m.peer_id)
           m.peer_id, m.peer_type, m.direction, m.msg_type,
           m.content_text, m.room_id, m.from_id, m.sender_name,
           m.device_guid, m.msg_time, m.created_at
    FROM public.wecom_super_messages m
    WHERE m.root_manager_id = v_root
    ORDER BY m.peer_id, m.msg_time DESC, m.created_at DESC
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(row)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT l.peer_id AS "peerId", l.peer_type AS "peerType",
           CASE WHEN l.peer_type = 'room'
                THEN COALESCE(NULLIF(r.name, ''), l.peer_id)
                ELSE COALESCE(NULLIF(c.name, ''), NULLIF(up.nickname, ''), l.peer_id)
           END AS "peerName",
           CASE WHEN l.peer_type = 'room' THEN r.avatar_url
                ELSE COALESCE(c.avatar_url, NULLIF(up.avatar_url, ''))
           END AS "avatarUrl",
           -- 私信对方是企业微信同事：与所属设备账号同企业号段或资料库标记
           (l.peer_type = 'contact'
             AND l.peer_id <> ''
             AND (up.is_internal
                  OR (left(l.peer_id, 6) = left(d.login_userid, 6)
                      AND l.peer_id <> d.login_userid))) AS "peerIsCorp",
           l.direction, l.msg_type AS "msgType",
           l.content_text AS "lastContent", l.msg_time AS "msgTime",
           (SELECT count(*) FROM public.wecom_super_messages m2
             WHERE m2.root_manager_id = v_root AND m2.peer_id = l.peer_id) AS "messageCount"
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
           OR COALESCE(c.name, '') ILIKE '%' || v_keyword || '%'
           OR COALESCE(up.nickname, '') ILIKE '%' || v_keyword || '%'
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
