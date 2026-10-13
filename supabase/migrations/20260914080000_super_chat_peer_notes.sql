-- 企微超级助手：微信式聊天 + 会话资料
-- 1) contacts/rooms 增加：remark_name（称呼/备注名）、intro（简介/习惯称呼/聊天注意事项）、
--    ai_reply_enabled（单会话 AI 自动回复开关，默认 true；VIP 客户可关）
-- 2) list_wecom_super_conversations/messages 增加 p_device_guid 外挂筛选，
--    显示名兜底链接入 remark_name，会话返回 lastDeviceGuid / aiReplyEnabled
-- 3) list_wecom_super_tasks 返回 targetsDetail（对象头像昵称）+ 发送设备头像昵称

-- ───────────────────────── 1. 会话资料字段 ─────────────────────────
ALTER TABLE public.wecom_super_contacts
  ADD COLUMN IF NOT EXISTS remark_name text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS intro text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS ai_reply_enabled boolean NOT NULL DEFAULT true;

ALTER TABLE public.wecom_super_rooms
  ADD COLUMN IF NOT EXISTS remark_name text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS intro text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS ai_reply_enabled boolean NOT NULL DEFAULT true;

-- ───────────────────────── 2. 会话列表 RPC（外挂筛选 + 备注 + AI开关 + 发送设备） ─────────────────────────
-- 参数签名变化（新增 p_device_guid），先删除旧重载，避免 PostgREST 重载歧义
DROP FUNCTION IF EXISTS public.list_wecom_super_conversations(text, text, int, int);
DROP FUNCTION IF EXISTS public.list_wecom_super_messages(text, int, int);

CREATE OR REPLACE FUNCTION public.list_wecom_super_conversations(
  p_keyword text DEFAULT NULL,
  p_peer_type text DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 20,
  p_device_guid text DEFAULT NULL
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
  v_guid text := NULLIF(btrim(COALESCE(p_device_guid, '')), '');
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
      AND (v_guid IS NULL OR m.device_guid = v_guid)
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
         OR COALESCE(c.remark_name, '') ILIKE '%' || v_keyword || '%'
         OR COALESCE(c.name, '') ILIKE '%' || v_keyword || '%'
         OR COALESCE(up.nickname, '') ILIKE '%' || v_keyword || '%'
         OR COALESCE(r.remark_name, '') ILIKE '%' || v_keyword || '%'
         OR COALESCE(r.name, '') ILIKE '%' || v_keyword || '%'
         OR l.peer_id ILIKE '%' || v_keyword || '%');

  WITH latest AS (
    SELECT DISTINCT ON (m.peer_id)
           m.peer_id, m.peer_type, m.direction, m.msg_type,
           m.content_text, m.room_id, m.from_id, m.sender_name,
           m.device_guid, m.msg_time, m.created_at
    FROM public.wecom_super_messages m
    WHERE m.root_manager_id = v_root
      AND (v_guid IS NULL OR m.device_guid = v_guid)
    ORDER BY m.peer_id, m.msg_time DESC, m.created_at DESC
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
           (SELECT count(*) FROM public.wecom_super_messages m2
             WHERE m2.root_manager_id = v_root AND m2.peer_id = l.peer_id
               AND (v_guid IS NULL OR m2.device_guid = v_guid)) AS "messageCount",
           l.device_guid AS "lastDeviceGuid",
           NULLIF(d.login_nickname, '') AS "deviceName",
           d.avatar_url AS "deviceAvatar",
           d.status AS "deviceStatus",
           -- 单会话 AI 开关（默认开）
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

REVOKE ALL ON FUNCTION public.list_wecom_super_conversations(text, text, int, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_conversations(text, text, int, int, text) TO authenticated;

-- ───────────────────────── 3. 消息流 RPC（外挂筛选 + 备注名 + AI开关） ─────────────────────────
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
    SELECT m.id, m.direction, m.msg_type AS "msgType", m.peer_type AS "peerType",
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

-- ───────────────────────── 4. 任务列表 RPC：对象头像昵称 + 发送设备 ─────────────────────────
CREATE OR REPLACE FUNCTION public.list_wecom_super_tasks(
  p_status text DEFAULT NULL,
  p_kind text DEFAULT NULL,
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
  v_status text := NULLIF(btrim(COALESCE(p_status, '')), '');
  v_kind text := NULLIF(btrim(COALESCE(p_kind, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
  v_offset int := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_total int;
  v_items jsonb;
BEGIN
  SELECT count(*) INTO v_total
  FROM public.wecom_super_send_tasks t
  WHERE t.root_manager_id = v_root
    AND (v_status IS NULL OR t.status = v_status)
    AND (v_kind IS NULL OR t.kind = v_kind);

  SELECT COALESCE(jsonb_agg(to_jsonb(row)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT t.id, t.kind, t.target_type AS "targetType", t.content,
           t.total_count AS "totalCount", t.sent_count AS "sentCount",
           t.fail_count AS "failCount", t.status, t.scheduled_at AS "scheduledAt",
           t.device_guid AS "deviceGuid", t.last_error AS "lastError",
           t.ai_suggestion_id AS "aiSuggestionId", t.result AS "result",
           t.created_by AS "createdBy", t.created_at AS "createdAt",
           t.updated_at AS "updatedAt",
           -- 发送者（外挂账号）
           NULLIF(dv.login_nickname, '') AS "deviceName",
           dv.avatar_url AS "deviceAvatar",
           dv.status AS "deviceStatus",
           -- 发送对象明细：targets 数组逐个关联好友/群头像昵称
           (
             SELECT COALESCE(jsonb_agg(p.obj ORDER BY p.ord), '[]'::jsonb)
             FROM (
               SELECT e.ord,
                      jsonb_build_object(
                        'id', e.id,
                        'peerType', CASE WHEN r.room_id IS NOT NULL THEN 'room'
                                        WHEN c.external_userid IS NOT NULL THEN 'contact' END,
                        'name', COALESCE(NULLIF(c.remark_name, ''), NULLIF(c.name, ''),
                                         NULLIF(r.remark_name, ''), NULLIF(r.name, ''),
                                         NULLIF(up.nickname, ''), e.id),
                        'avatarUrl', COALESCE(c.avatar_url, r.avatar_url,
                                              NULLIF(up.avatar_url, ''))
                      ) AS obj
               FROM jsonb_array_elements_text(
                      CASE
                        -- 正常数组
                        WHEN jsonb_typeof(t.targets) = 'array' THEN t.targets
                        -- 历史脏数据：targets 被双重编码成「数组文本字符串」（如 "[\"id\"]"）
                        WHEN jsonb_typeof(t.targets) = 'string'
                             AND left(t.targets #>> '{}', 1) = '['
                             AND jsonb_typeof((t.targets #>> '{}')::jsonb) = 'array'
                          THEN (t.targets #>> '{}')::jsonb
                        -- 历史脏数据：单个 id 裸字符串
                        WHEN jsonb_typeof(t.targets) = 'string'
                          THEN jsonb_build_array(t.targets)
                        ELSE '[]'::jsonb
                      END
                    )
                    WITH ORDINALITY AS e(id, ord)
               LEFT JOIN public.wecom_super_contacts c
                 ON c.root_manager_id = v_root AND c.external_userid = e.id
               LEFT JOIN public.wecom_super_rooms r
                 ON r.root_manager_id = v_root AND r.room_id = e.id
               LEFT JOIN public.wecom_super_user_profiles up
                 ON up.root_manager_id = v_root AND up.user_id = e.id
             ) p
           ) AS "targetsDetail"
    FROM public.wecom_super_send_tasks t
    LEFT JOIN public.wecom_super_devices dv
      ON dv.root_manager_id = v_root AND dv.guid = t.device_guid
    WHERE t.root_manager_id = v_root
      AND (v_status IS NULL OR t.status = v_status)
      AND (v_kind IS NULL OR t.kind = v_kind)
    ORDER BY t.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_tasks(text, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_tasks(text, text, int, int) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. 好友列表 / 群列表 RPC：返回 remark_name / intro / ai_reply_enabled，搜索含备注名
--    签名不变，CREATE OR REPLACE 即可
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.list_wecom_super_contacts(
  p_keyword text DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 20,
  p_device_guid text DEFAULT NULL,
  p_tag_ids text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
  v_keyword text := NULLIF(btrim(COALESCE(p_keyword, '')), '');
  v_device text := NULLIF(btrim(COALESCE(p_device_guid, '')), '');
  v_tags text[] := NULLIF(p_tag_ids, '{}'::text[]);
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 200);
  v_offset int := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_total int;
  v_items jsonb;
BEGIN
  SELECT count(*) INTO v_total
  FROM public.wecom_super_contacts c
  WHERE c.root_manager_id = v_root
    AND (v_device IS NULL OR c.device_guid = v_device)
    AND (v_keyword IS NULL
         OR COALESCE(c.name, '') ILIKE '%' || v_keyword || '%'
         OR COALESCE(c.remark_name, '') ILIKE '%' || v_keyword || '%'
         OR c.external_userid ILIKE '%' || v_keyword || '%'
         OR COALESCE(c.account, '') ILIKE '%' || v_keyword || '%')
    AND (v_tags IS NULL OR EXISTS (
      SELECT 1
      FROM public.merchant_wecom_contact_tags ct
      WHERE ct.root_manager_id = v_root
        AND ct.tag_id = ANY(v_tags)
        AND (
          ct.external_userid = c.external_userid
          OR EXISTS (
            SELECT 1 FROM public.wecom_super_contact_mapping m
            WHERE m.root_manager_id = v_root
              AND m.super_device_guid = c.device_guid
              AND m.super_external_userid = c.external_userid
              AND m.pro_external_userid = ct.external_userid
          )
        )
    ));

  SELECT COALESCE(jsonb_agg(to_jsonb(row)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT c.id, c.external_userid AS "externalUserid", c.name, c.avatar_url AS "avatarUrl",
           c.contact_type AS "contactType", c.account, c.device_guid AS "deviceGuid",
           c.synced_at AS "syncedAt",
           COALESCE(c.remark_name, '') AS "remarkName",
           COALESCE(c.intro, '') AS "intro",
           COALESCE(c.ai_reply_enabled, true) AS "aiReplyEnabled"
    FROM public.wecom_super_contacts c
    WHERE c.root_manager_id = v_root
      AND (v_device IS NULL OR c.device_guid = v_device)
      AND (v_keyword IS NULL
           OR COALESCE(c.name, '') ILIKE '%' || v_keyword || '%'
           OR COALESCE(c.remark_name, '') ILIKE '%' || v_keyword || '%'
           OR c.external_userid ILIKE '%' || v_keyword || '%'
           OR COALESCE(c.account, '') ILIKE '%' || v_keyword || '%')
      AND (v_tags IS NULL OR EXISTS (
        SELECT 1
        FROM public.merchant_wecom_contact_tags ct
        WHERE ct.root_manager_id = v_root
          AND ct.tag_id = ANY(v_tags)
        AND (
          ct.external_userid = c.external_userid
          OR EXISTS (
            SELECT 1 FROM public.wecom_super_contact_mapping m
            WHERE m.root_manager_id = v_root
              AND m.super_device_guid = c.device_guid
              AND m.super_external_userid = c.external_userid
              AND m.pro_external_userid = ct.external_userid
          )
        )
      ))
    ORDER BY c.synced_at DESC NULLS LAST, c.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_contacts(text, int, int, text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_contacts(text, int, int, text, text[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.list_wecom_super_rooms(
  p_keyword text DEFAULT NULL,
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
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 200);
  v_offset int := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_total int;
  v_items jsonb;
BEGIN
  SELECT count(*) INTO v_total
  FROM public.wecom_super_rooms r
  WHERE r.root_manager_id = v_root
    AND (v_keyword IS NULL
         OR COALESCE(r.name, '') ILIKE '%' || v_keyword || '%'
         OR COALESCE(r.remark_name, '') ILIKE '%' || v_keyword || '%'
         OR r.room_id ILIKE '%' || v_keyword || '%');

  SELECT COALESCE(jsonb_agg(to_jsonb(row)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT r.id, r.room_id AS "roomId", r.name, r.avatar_url AS "avatarUrl",
           r.member_count AS "memberCount", r.owner_id AS "ownerId",
           r.is_outer_room AS "isOuterRoom", r.device_guid AS "deviceGuid",
           r.synced_at AS "syncedAt",
           COALESCE(r.remark_name, '') AS "remarkName",
           COALESCE(r.intro, '') AS "intro",
           COALESCE(r.ai_reply_enabled, true) AS "aiReplyEnabled"
    FROM public.wecom_super_rooms r
    WHERE r.root_manager_id = v_root
      AND (v_keyword IS NULL
           OR COALESCE(r.name, '') ILIKE '%' || v_keyword || '%'
           OR COALESCE(r.remark_name, '') ILIKE '%' || v_keyword || '%'
           OR r.room_id ILIKE '%' || v_keyword || '%')
    ORDER BY r.synced_at DESC NULLS LAST, r.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_rooms(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_rooms(text, int, int) TO authenticated;
