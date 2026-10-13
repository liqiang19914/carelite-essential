-- ============================================================================
-- 会话存档 —— 消息显示修复
-- 1) 历史 content 被 EF 存成 jsonb 字符串（双重 JSON 编码），统一解包成对象
-- 2) 群聊会话名兜底：rooms.room_name 为空时取客户群同步表 merchant_wecom_chat_groups.name
-- 3) 消息流 msgAt 改为 timestamptz（之前 AT TIME ZONE 'UTC' 去掉时区，前端按本地解析差 8 小时）
-- 4) 消息流补 fromName：员工 → profiles(real_name/nickname)，客户 → merchant_wecom_contacts.name
-- ============================================================================

-- 1) 解包双重编码的 content（jsonb 字符串 → 其内部 JSON）
UPDATE public.merchant_wecom_archive_messages
SET content = (content #>> '{}')::jsonb
WHERE jsonb_typeof(content) = 'string'
  AND btrim(content #>> '{}') LIKE '{%';

-- 2) 会话列表：群聊名取客户群表兜底，关键词搜索覆盖群名
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
  IF NOT public.wecom_pro_module_open(v_root) THEN
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
               COALESCE(NULLIF(btrim(r.room_name), ''), NULLIF(btrim(g.name), ''), r.roomid)
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

-- 3) 会话详情：群聊名同样取客户群表兜底
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
  IF NOT public.wecom_pro_module_open(v_root) THEN
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
               COALESCE(NULLIF(btrim(r.room_name), ''), NULLIF(btrim(g.name), ''), r.roomid)
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

-- 4) 消息流：msgAt 带时区 + 发送人姓名（员工/客户）
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
  IF NOT public.wecom_pro_module_open(v_root) THEN
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

-- 5) 兜底群名：不在客户群同步表里的群（如临时群），用存档消息参与人真名拼名
CREATE OR REPLACE FUNCTION public.wecom_archive_participant_names(v_root uuid, v_roomid text)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT left(string_agg(nm, '、' ORDER BY is_external, nm), 60)
  FROM (
    SELECT DISTINCT ON (uid) uid,
      CASE WHEN uid ~ '^(wm|wo)'
           THEN COALESCE(NULLIF((
                  SELECT btrim(c.name) FROM public.merchant_wecom_contacts c
                  WHERE c.root_manager_id = v_root AND c.external_userid = uid
                ), ''), uid)
           ELSE COALESCE(NULLIF(regexp_replace((
                  SELECT btrim(COALESCE(NULLIF(p.real_name, ''), p.nickname))
                  FROM public.profiles p
                  WHERE p.wecom_userid = uid
                    AND public.get_enterprise_root_manager_id(p.id) = v_root
                ), '@[A-Za-z0-9._-]+\.[A-Za-z]{2,}$', ''), ''), uid)
      END AS nm,
      (uid ~ '^(wm|wo)')::boolean AS is_external
    FROM (
      SELECT m.from_userid AS uid FROM public.merchant_wecom_archive_messages m
      WHERE m.root_manager_id = v_root AND m.roomid = v_roomid AND m.from_userid IS NOT NULL
      UNION
      SELECT unnest(m.tolist) FROM public.merchant_wecom_archive_messages m
      WHERE m.root_manager_id = v_root AND m.roomid = v_roomid
    ) u
  ) z
$function$;

REVOKE ALL ON FUNCTION public.wecom_archive_participant_names(uuid, text) FROM PUBLIC;

-- 群参与人数（客户群表未覆盖的临时群兜底）
CREATE OR REPLACE FUNCTION public.wecom_archive_participant_count(v_root uuid, v_roomid text)
RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT count(DISTINCT uid)::int
  FROM (
    SELECT m.from_userid AS uid FROM public.merchant_wecom_archive_messages m
    WHERE m.root_manager_id = v_root AND m.roomid = v_roomid AND m.from_userid IS NOT NULL
    UNION
    SELECT unnest(m.tolist) FROM public.merchant_wecom_archive_messages m
    WHERE m.root_manager_id = v_root AND m.roomid = v_roomid
  ) u
$function$;

REVOKE ALL ON FUNCTION public.wecom_archive_participant_count(uuid, text) FROM PUBLIC;

-- 6.6b 会话列表重建：群名兜底链 room_name → 客户群表 → 参与人拼名 → roomid
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
  IF NOT public.wecom_pro_module_open(v_root) THEN
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

-- 6.8b 会话详情重建：同样的群名兜底链
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
  IF NOT public.wecom_pro_module_open(v_root) THEN
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
