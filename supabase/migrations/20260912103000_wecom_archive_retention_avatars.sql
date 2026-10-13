-- ============================================================================
-- 会话存档 —— 到期保留 + 头像/成员
--
-- 业务要求：会话存档服务到期不续费后，停止采集新消息（EF config 已按 module
-- grant 过滤租户，到期自动移出采集清单），但到期前入仓的历史聊天记录必须
-- 永久保留、随时可查。本迁移把存档只读 RPC 的门槛从「Pro 模块在有效期」
-- 放宽为「模块在有效期 或 该商户有存档配置/历史数据」，并：
--   1. 消息流补发送人头像（员工 profiles.avatar_url / 客户 contacts.avatar_url）
--   2. 新增会话成员接口（群聊点群名看成员头像列表；同步表优先，临时群取消息参与人）
--   3. config 返回 moduleOpen，前端据此展示「已到期·历史保留」提示
-- ============================================================================

-- 0) 历史可读门槛
CREATE OR REPLACE FUNCTION public.wecom_archive_readable(v_root uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT public.wecom_pro_module_open(v_root)
      OR EXISTS (
        SELECT 1 FROM public.merchant_wecom_settings s
        WHERE s.root_manager_id = v_root AND COALESCE(s.archive_enabled, false)
      )
      OR EXISTS (
        SELECT 1 FROM public.merchant_wecom_archive_messages m WHERE m.root_manager_id = v_root
      )
      OR EXISTS (
        SELECT 1 FROM public.merchant_wecom_archive_rooms r WHERE r.root_manager_id = v_root
      )
$function$;

REVOKE ALL ON FUNCTION public.wecom_archive_readable(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.wecom_archive_readable(uuid) TO authenticated;

-- 1) 配置卡：门槛放宽 + moduleOpen 标志（到期商户进入页面只看历史）
CREATE OR REPLACE FUNCTION public.get_wecom_pro_archive_config()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_s public.merchant_wecom_settings%ROWTYPE;
  v_slug text;
  v_room_count int;
  v_msg_count bigint;
  v_today_msg int;
  v_sensitive_count int;
  v_latest_msg bigint;
  v_platform_ip text;
  v_event_url text;
  v_event_ready boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;
  IF NOT public.wecom_archive_readable(v_root) THEN
    RAISE EXCEPTION '企微助手 Pro 尚未开通' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('wecom_pro_archive', v_uid) THEN
    RAISE EXCEPTION '没有会话存档权限' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_s FROM public.merchant_wecom_settings WHERE root_manager_id = v_root;
  SELECT btrim(brand_slug) INTO v_slug FROM public.managers WHERE id = v_root;

  IF COALESCE(btrim(v_s.callback_domain), '') <> '' AND COALESCE(v_slug, '') <> '' THEN
    v_event_url := 'https://' || btrim(v_s.callback_domain) || '/wecom/callback?slug=' || v_slug;
  END IF;
  v_event_ready := v_event_url IS NOT NULL
                   AND COALESCE(btrim(v_s.single_chat_token), '') <> ''
                   AND COALESCE(btrim(v_s.single_chat_aes_key), '') <> '';

  SELECT NULLIF(btrim(value), '') INTO v_platform_ip
  FROM public.system_settings
  WHERE key = 'wecom_archive_collector_ip';

  SELECT
    (SELECT count(*)::int FROM public.merchant_wecom_archive_rooms WHERE root_manager_id = v_root),
    (SELECT count(*) FROM public.merchant_wecom_archive_messages WHERE root_manager_id = v_root),
    (SELECT count(*)::int FROM public.merchant_wecom_archive_messages
      WHERE root_manager_id = v_root AND created_at >= date_trunc('day', now())),
    (SELECT count(*)::int FROM public.merchant_wecom_archive_messages
      WHERE root_manager_id = v_root AND sensitive_hit),
    (SELECT (max(msgtime) / 1000)::bigint FROM public.merchant_wecom_archive_messages
      WHERE root_manager_id = v_root)
  INTO v_room_count, v_msg_count, v_today_msg, v_sensitive_count, v_latest_msg;

  RETURN jsonb_build_object(
    'enabled', COALESCE(v_s.archive_enabled, false),
    'moduleOpen', public.wecom_pro_module_open(v_root),
    'hasSecret', COALESCE(v_s.archive_secret, '') <> '',
    'secretTail', CASE WHEN COALESCE(v_s.archive_secret, '') <> ''
                       THEN right(v_s.archive_secret, 4) ELSE NULL END,
    'privateKeys', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('publickeyVer', k->>'publickey_ver', 'hasKey', true)
                       ORDER BY k->>'publickey_ver')
      FROM jsonb_array_elements(COALESCE(v_s.archive_private_keys, '[]'::jsonb)) k
    ), '[]'::jsonb),
    'checkedAt', v_s.archive_checked_at,
    'lastSeq', COALESCE(v_s.archive_last_seq, 0),
    'collectorHeartbeat', v_s.archive_collector_heartbeat,
    'collectorIp', v_s.archive_collector_ip,
    'collectorError', NULLIF(btrim(COALESCE(v_s.archive_collector_error, '')), ''),
    'platformCollectorIp', v_platform_ip,
    'corpId', NULLIF(btrim(COALESCE(v_s.single_chat_corp_id, '')), ''),
    'eventServerUrl', v_event_url,
    'eventServerToken', NULLIF(btrim(COALESCE(v_s.single_chat_token, '')), ''),
    'eventServerAesKey', NULLIF(btrim(COALESCE(v_s.single_chat_aes_key, '')), ''),
    'eventServerReady', v_event_ready,
    'roomCount', COALESCE(v_room_count, 0),
    'messageCount', COALESCE(v_msg_count, 0),
    'todayMessageCount', COALESCE(v_today_msg, 0),
    'sensitiveCount', COALESCE(v_sensitive_count, 0),
    'latestMessageAt', v_latest_msg
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_wecom_pro_archive_config() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wecom_pro_archive_config() TO authenticated;

-- 2) 会话列表：门槛改为历史可读（其余展示逻辑不变）
CREATE OR REPLACE FUNCTION public.list_wecom_pro_archive_rooms(
  p_room_type text DEFAULT '',
  p_keyword text DEFAULT '',
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_is_admin boolean;
  v_my_userid text;
  v_type text := btrim(COALESCE(p_room_type, ''));
  v_kw text := btrim(COALESCE(p_keyword, ''));
  v_page int := GREATEST(COALESCE(p_page, 1), 1);
  v_size int := LEAST(GREATEST(COALESCE(p_page_size, 30), 1), 100);
  v_total int;
  v_items jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;
  IF NOT public.wecom_archive_readable(v_root) THEN
    RAISE EXCEPTION '企微助手 Pro 尚未开通' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('wecom_pro_archive', v_uid) THEN
    RAISE EXCEPTION '没有会话存档权限' USING ERRCODE = '42501';
  END IF;

  v_is_admin := public.is_enterprise_admin(v_uid);
  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
    v_my_userid := btrim(COALESCE(v_my_userid, ''));
  END IF;

  SELECT count(*)::int INTO v_total
  FROM public.merchant_wecom_archive_rooms r
  LEFT JOIN public.merchant_wecom_contacts c
    ON c.root_manager_id = r.root_manager_id AND c.external_userid = r.external_userid
  LEFT JOIN public.merchant_wecom_chat_groups g
    ON g.root_manager_id = r.root_manager_id AND g.chat_id = r.roomid
  WHERE r.root_manager_id = v_root
    AND (v_type = '' OR r.room_type = v_type)
    AND (
      v_kw = ''
      OR r.room_name ILIKE '%' || v_kw || '%'
      OR COALESCE(c.name, '') ILIKE '%' || v_kw || '%'
      OR COALESCE(g.name, '') ILIKE '%' || v_kw || '%'
      OR r.external_userid ILIKE '%' || v_kw || '%'
    )
    AND (
      v_is_admin
      OR (v_my_userid <> '' AND v_my_userid = ANY (r.staff_userids))
    );

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t."lastMsgAt" DESC NULLS LAST), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT r.roomid, r.room_type AS "roomType",
           CASE r.room_type
             WHEN 'group' THEN
               COALESCE(NULLIF(btrim(r.room_name), ''), NULLIF(btrim(g.name), ''),
                        public.wecom_archive_participant_names(v_root, r.roomid), r.roomid)
             ELSE
               COALESCE(NULLIF(btrim(r.room_name), ''), NULLIF(btrim(c.name), ''), r.external_userid, r.roomid)
           END AS "roomName",
           r.external_userid AS "externalUserid",
           r.owner_userid AS "ownerUserid", r.staff_userids AS "staffUserids",
           GREATEST(r.member_count, public.wecom_archive_participant_count(v_root, r.roomid)) AS "memberCount",
           r.last_msg_at AS "lastMsgAt",
           NULLIF(btrim(r.last_msg_summary), '') AS "lastMsgSummary",
           r.sensitive_count AS "sensitiveCount"
    FROM public.merchant_wecom_archive_rooms r
    LEFT JOIN public.merchant_wecom_contacts c
      ON c.root_manager_id = r.root_manager_id AND c.external_userid = r.external_userid
    LEFT JOIN public.merchant_wecom_chat_groups g
      ON g.root_manager_id = r.root_manager_id AND g.chat_id = r.roomid
    WHERE r.root_manager_id = v_root
      AND (v_type = '' OR r.room_type = v_type)
      AND (
        v_kw = ''
        OR r.room_name ILIKE '%' || v_kw || '%'
        OR COALESCE(c.name, '') ILIKE '%' || v_kw || '%'
        OR COALESCE(g.name, '') ILIKE '%' || v_kw || '%'
        OR r.external_userid ILIKE '%' || v_kw || '%'
      )
      AND (
        v_is_admin
        OR (v_my_userid <> '' AND v_my_userid = ANY (r.staff_userids))
      )
    ORDER BY r.last_msg_at DESC NULLS LAST
    LIMIT v_size OFFSET (v_page - 1) * v_size
  ) t;

  RETURN jsonb_build_object(
    'items', v_items,
    'total', v_total,
    'page', v_page,
    'pageSize', v_size,
    'totalPages', GREATEST(CEIL(v_total::numeric / NULLIF(v_size, 0)), 1)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_pro_archive_rooms(text, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_pro_archive_rooms(text, text, int, int) TO authenticated;

-- 3) 会话详情：门槛改为历史可读
CREATE OR REPLACE FUNCTION public.get_wecom_pro_archive_room(p_roomid text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_is_admin boolean;
  v_my_userid text;
  v_roomid text := btrim(COALESCE(p_roomid, ''));
  v_visible boolean;
  v_out jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;
  IF NOT public.wecom_archive_readable(v_root) THEN
    RAISE EXCEPTION '企微助手 Pro 尚未开通' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('wecom_pro_archive', v_uid) THEN
    RAISE EXCEPTION '没有会话存档权限' USING ERRCODE = '42501';
  END IF;
  IF v_roomid = '' THEN
    RAISE EXCEPTION '缺少会话 ID' USING ERRCODE = '22023';
  END IF;

  v_is_admin := public.is_enterprise_admin(v_uid);
  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
    v_my_userid := btrim(COALESCE(v_my_userid, ''));
  END IF;

  SELECT (v_is_admin OR (v_my_userid <> '' AND v_my_userid = ANY (r.staff_userids))) INTO v_visible
  FROM public.merchant_wecom_archive_rooms r
  WHERE r.root_manager_id = v_root AND r.roomid = v_roomid;

  IF v_visible IS NULL THEN
    RAISE EXCEPTION '会话不存在' USING ERRCODE = 'P0002';
  END IF;
  IF NOT v_visible THEN
    RAISE EXCEPTION '无权查看该会话' USING ERRCODE = '42501';
  END IF;

  SELECT to_jsonb(x) INTO v_out
  FROM (
    SELECT r.roomid, r.room_type AS "roomType",
           CASE r.room_type
             WHEN 'group' THEN
               COALESCE(NULLIF(btrim(r.room_name), ''), NULLIF(btrim(g.name), ''),
                        public.wecom_archive_participant_names(v_root, r.roomid), r.roomid)
             ELSE
               COALESCE(NULLIF(btrim(r.room_name), ''), NULLIF(btrim(c.name), ''), r.external_userid, r.roomid)
           END AS "roomName",
           r.external_userid AS "externalUserid", r.owner_userid AS "ownerUserid",
           r.staff_userids AS "staffUserids",
           r.member_count AS "memberCount", r.last_msg_at AS "lastMsgAt",
           r.last_msg_summary AS "lastMsgSummary", r.sensitive_count AS "sensitiveCount"
    FROM public.merchant_wecom_archive_rooms r
    LEFT JOIN public.merchant_wecom_contacts c
      ON c.root_manager_id = r.root_manager_id AND c.external_userid = r.external_userid
    LEFT JOIN public.merchant_wecom_chat_groups g
      ON g.root_manager_id = r.root_manager_id AND g.chat_id = r.roomid
    WHERE r.root_manager_id = v_root AND r.roomid = v_roomid
  ) x;

  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_wecom_pro_archive_room(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wecom_pro_archive_room(text) TO authenticated;

-- 4) 消息流：门槛改为历史可读 + 发送人头像
CREATE OR REPLACE FUNCTION public.list_wecom_pro_archive_messages(
  p_roomid text,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_is_admin boolean;
  v_my_userid text;
  v_roomid text := btrim(COALESCE(p_roomid, ''));
  v_page int := GREATEST(COALESCE(p_page, 1), 1);
  v_size int := LEAST(GREATEST(COALESCE(p_page_size, 50), 1), 200);
  v_total int;
  v_items jsonb;
  v_visible boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;
  IF NOT public.wecom_archive_readable(v_root) THEN
    RAISE EXCEPTION '企微助手 Pro 尚未开通' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('wecom_pro_archive', v_uid) THEN
    RAISE EXCEPTION '没有会话存档权限' USING ERRCODE = '42501';
  END IF;
  IF v_roomid = '' THEN
    RAISE EXCEPTION '缺少会话 ID' USING ERRCODE = '22023';
  END IF;

  v_is_admin := public.is_enterprise_admin(v_uid);
  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
    v_my_userid := btrim(COALESCE(v_my_userid, ''));
    SELECT (v_my_userid <> '' AND v_my_userid = ANY (staff_userids)) INTO v_visible
    FROM public.merchant_wecom_archive_rooms
    WHERE root_manager_id = v_root AND roomid = v_roomid;
    IF NOT COALESCE(v_visible, false) THEN
      RAISE EXCEPTION '无权查看该会话' USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT count(*)::int INTO v_total
  FROM public.merchant_wecom_archive_messages m
  WHERE m.root_manager_id = v_root AND m.roomid = v_roomid;

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.msgtime ASC NULLS LAST), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT m.msgid, m.seq, m.action, m.roomid,
           m.room_type AS "roomType", m.from_userid AS "fromUserid",
           COALESCE(
             NULLIF(btrim(m.from_name), ''),
             NULLIF(regexp_replace(btrim(p.real_name), '@[A-Za-z0-9._-]+\.[A-Za-z]{2,}$', ''), ''),
             NULLIF(regexp_replace(btrim(p.nickname), '@[A-Za-z0-9._-]+\.[A-Za-z]{2,}$', ''), ''),
             NULLIF(btrim(c.name), '')
           ) AS "fromName",
           regexp_replace(COALESCE(NULLIF(btrim(p.avatar_url), ''), NULLIF(btrim(c.avatar_url), '')), '^http://', 'https://') AS "fromAvatar",
           m.tolist, m.msg_type AS "msgType", m.content, m.media_url AS "mediaUrl", m.msgtime,
           m.sensitive_hit AS "sensitiveHit", m.sensitive_words AS "sensitiveWords",
           to_timestamp(m.msgtime::numeric / 1000.0) AS "msgAt"
    FROM public.merchant_wecom_archive_messages m
    LEFT JOIN public.profiles p
      ON p.wecom_userid = m.from_userid
     AND public.get_enterprise_root_manager_id(p.id) = v_root
    LEFT JOIN public.merchant_wecom_contacts c
      ON c.root_manager_id = m.root_manager_id AND c.external_userid = m.from_userid
    WHERE m.root_manager_id = v_root AND m.roomid = v_roomid
    ORDER BY m.msgtime DESC NULLS LAST
    LIMIT v_size OFFSET (v_page - 1) * v_size
  ) t;

  RETURN jsonb_build_object(
    'items', v_items,
    'total', v_total,
    'page', v_page,
    'pageSize', v_size,
    'totalPages', GREATEST(CEIL(v_total::numeric / NULLIF(v_size, 0)), 1)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_pro_archive_messages(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_pro_archive_messages(text, int, int) TO authenticated;

-- 5) 会话成员（群聊点群名）：客户群同步表优先；未同步的临时群/单聊取消息参与人
CREATE OR REPLACE FUNCTION public.get_wecom_pro_archive_room_members(p_roomid text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_is_admin boolean;
  v_my_userid text;
  v_roomid text := btrim(COALESCE(p_roomid, ''));
  v_room_type text;
  v_visible boolean;
  v_items jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;
  IF NOT public.wecom_archive_readable(v_root) THEN
    RAISE EXCEPTION '企微助手 Pro 尚未开通' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_enterprise_permission('wecom_pro_archive', v_uid) THEN
    RAISE EXCEPTION '没有会话存档权限' USING ERRCODE = '42501';
  END IF;
  IF v_roomid = '' THEN
    RAISE EXCEPTION '缺少会话 ID' USING ERRCODE = '22023';
  END IF;

  v_is_admin := public.is_enterprise_admin(v_uid);
  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
    v_my_userid := btrim(COALESCE(v_my_userid, ''));
    SELECT room_type INTO v_room_type
    FROM public.merchant_wecom_archive_rooms
    WHERE root_manager_id = v_root AND roomid = v_roomid;
    IF v_room_type IS NULL THEN
      RAISE EXCEPTION '会话不存在' USING ERRCODE = 'P0002';
    END IF;
    SELECT (v_my_userid <> '' AND v_my_userid = ANY (staff_userids)) INTO v_visible
    FROM public.merchant_wecom_archive_rooms
    WHERE root_manager_id = v_root AND roomid = v_roomid;
    IF NOT COALESCE(v_visible, false) THEN
      RAISE EXCEPTION '无权查看该会话' USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT room_type INTO v_room_type
  FROM public.merchant_wecom_archive_rooms
  WHERE root_manager_id = v_root AND roomid = v_roomid;
  IF v_room_type IS NULL THEN
    v_room_type := CASE WHEN v_roomid LIKE 'wr%' THEN 'group'
                        WHEN v_roomid LIKE 'single:%' THEN 'single' END;
  END IF;
  IF v_room_type IS NULL THEN
    RAISE EXCEPTION '会话不存在' USING ERRCODE = 'P0002';
  END IF;

  IF v_room_type = 'group'
     AND EXISTS (SELECT 1 FROM public.merchant_wecom_chat_group_members
                 WHERE root_manager_id = v_root AND chat_id = v_roomid) THEN
    -- 已同步客户群：用群成员表（入群时间/类型），头像与昵称补 profiles / 客户库
    -- （企微 groupchat 接口不回传头像，member_id 对员工是 corp userid、对外部人是 external_userid）
    SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t."memberType" = 'member' DESC, t.name NULLS LAST), '[]'::jsonb)
    INTO v_items
    FROM (
      SELECT g.member_id AS "userId",
             CASE g.member_type WHEN 'external' THEN 'external' ELSE 'member' END AS "memberType",
             COALESCE(
               NULLIF(btrim(g.name), ''),
               NULLIF(regexp_replace(btrim(p.real_name), '@[A-Za-z0-9._-]+\.[A-Za-z]{2,}$', ''), ''),
               NULLIF(regexp_replace(btrim(p.nickname), '@[A-Za-z0-9._-]+\.[A-Za-z]{2,}$', ''), ''),
               NULLIF(btrim(c.name), ''),
               g.member_id
             ) AS "name",
             regexp_replace(COALESCE(
               NULLIF(btrim(g.avatar_url), ''),
               NULLIF(btrim(p.avatar_url), ''),
               NULLIF(btrim(c.avatar_url), '')
             ), '^http://', 'https://') AS "avatarUrl",
             g.joined_at AS "joinedAt"
      FROM public.merchant_wecom_chat_group_members g
      LEFT JOIN public.profiles p
        ON p.wecom_userid = g.member_id
       AND g.member_type <> 'external'
       AND public.get_enterprise_root_manager_id(p.id) = v_root
      LEFT JOIN public.merchant_wecom_contacts c
        ON c.root_manager_id = v_root
       AND g.member_type = 'external'
       AND c.external_userid = g.member_id
      WHERE g.root_manager_id = v_root AND g.chat_id = v_roomid
    ) t;
  ELSE
    -- 未同步群 / 单聊：从存档消息参与人 + 房间记录还原
    SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t."memberType" = 'member' DESC, t.name NULLS LAST), '[]'::jsonb)
    INTO v_items
    FROM (
      SELECT z.uid AS "userId",
             CASE WHEN z.uid ~ '^(wm|wo)' THEN 'external' ELSE 'member' END AS "memberType",
             COALESCE(
               NULLIF(regexp_replace(btrim(p.real_name), '@[A-Za-z0-9._-]+\.[A-Za-z]{2,}$', ''), ''),
               NULLIF(regexp_replace(btrim(p.nickname), '@[A-Za-z0-9._-]+\.[A-Za-z]{2,}$', ''), ''),
               NULLIF(btrim(c.name), ''),
               z.uid
             ) AS "name",
             regexp_replace(COALESCE(NULLIF(btrim(p.avatar_url), ''), NULLIF(btrim(c.avatar_url), '')), '^http://', 'https://') AS "avatarUrl",
             NULL::timestamptz AS "joinedAt"
      FROM (
        SELECT DISTINCT uid FROM (
          SELECT m.from_userid AS uid
          FROM public.merchant_wecom_archive_messages m
          WHERE m.root_manager_id = v_root AND m.roomid = v_roomid AND m.from_userid IS NOT NULL
          UNION
          SELECT unnest(m.tolist)
          FROM public.merchant_wecom_archive_messages m
          WHERE m.root_manager_id = v_root AND m.roomid = v_roomid
          UNION
          SELECT unnest(r.staff_userids)
          FROM public.merchant_wecom_archive_rooms r
          WHERE r.root_manager_id = v_root AND r.roomid = v_roomid
          UNION
          SELECT r.external_userid
          FROM public.merchant_wecom_archive_rooms r
          WHERE r.root_manager_id = v_root AND r.roomid = v_roomid
        ) u WHERE btrim(uid) <> ''
      ) z
      LEFT JOIN public.profiles p
        ON p.wecom_userid = z.uid
       AND public.get_enterprise_root_manager_id(p.id) = v_root
      LEFT JOIN public.merchant_wecom_contacts c
        ON c.root_manager_id = v_root AND c.external_userid = z.uid
    ) t;
  END IF;

  RETURN jsonb_build_object(
    'roomid', v_roomid,
    'roomType', v_room_type,
    'members', v_items
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_wecom_pro_archive_room_members(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wecom_pro_archive_room_members(text) TO authenticated;
