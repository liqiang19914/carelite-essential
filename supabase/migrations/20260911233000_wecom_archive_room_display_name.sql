-- ============================================================================
-- 会话存档 —— 会话列表/详情显示客户昵称
--
-- 单聊房间 room_name 采集端无法获得（存档消息体不含外部联系人昵称），
-- 之前列表显示 'single:wmXXXX' 原始 ID。这里关联客户库 merchant_wecom_contacts
-- 取 name 作为展示名（群聊仍用群名 room_name），搜索同时匹配客户昵称。
-- 仅改两个查询 RPC 的展示层，不动任何已落库数据。
-- ============================================================================

-- 6.6 会话房间列表（分页 + 单聊/群聊筛选 + 关键词 + 权限：管理员全部 / 员工仅自己参与）
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
  WHERE r.root_manager_id = v_root
    AND (v_type = '' OR r.room_type = v_type)
    AND (
      v_kw = ''
      OR r.room_name ILIKE '%' || v_kw || '%'
      OR COALESCE(c.name, '') ILIKE '%' || v_kw || '%'
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
           COALESCE(NULLIF(btrim(r.room_name), ''), NULLIF(btrim(c.name), ''), r.external_userid, r.roomid) AS "roomName",
           r.external_userid AS "externalUserid",
           r.owner_userid AS "ownerUserid", r.staff_userids AS "staffUserids", r.member_count AS "memberCount",
           r.last_msg_at AS "lastMsgAt",
           NULLIF(btrim(r.last_msg_summary), '') AS "lastMsgSummary",
           r.sensitive_count AS "sensitiveCount"
    FROM public.merchant_wecom_archive_rooms r
    LEFT JOIN public.merchant_wecom_contacts c
      ON c.root_manager_id = r.root_manager_id AND c.external_userid = r.external_userid
    WHERE r.root_manager_id = v_root
      AND (v_type = '' OR r.room_type = v_type)
      AND (
        v_kw = ''
        OR r.room_name ILIKE '%' || v_kw || '%'
        OR COALESCE(c.name, '') ILIKE '%' || v_kw || '%'
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

-- 6.8 会话详情（含权限校验）：room_name 同样取客户昵称兜底
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
           COALESCE(NULLIF(btrim(r.room_name), ''), NULLIF(btrim(c.name), ''), r.external_userid, r.roomid) AS "roomName",
           r.external_userid AS "externalUserid", r.owner_userid AS "ownerUserid",
           r.staff_userids AS "staffUserids",
           r.member_count AS "memberCount", r.last_msg_at AS "lastMsgAt",
           r.last_msg_summary AS "lastMsgSummary", r.sensitive_count AS "sensitiveCount"
    FROM public.merchant_wecom_archive_rooms r
    LEFT JOIN public.merchant_wecom_contacts c
      ON c.root_manager_id = r.root_manager_id AND c.external_userid = r.external_userid
    WHERE r.root_manager_id = v_root AND r.roomid = v_roomid
  ) x;

  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_wecom_pro_archive_room(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wecom_pro_archive_room(text) TO authenticated;

-- 6.7 会话消息流：输出列改为前端约定的 camelCase（to_jsonb 保留列别名大小写）
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
           m.room_type AS "roomType", m.from_userid AS "fromUserid", m.from_name AS "fromName",
           m.tolist, m.msg_type AS "msgType", m.content, m.media_url AS "mediaUrl", m.msgtime,
           m.sensitive_hit AS "sensitiveHit", m.sensitive_words AS "sensitiveWords",
           to_timestamp(m.msgtime::numeric / 1000.0) AT TIME ZONE 'UTC' AS "msgAt"
    FROM public.merchant_wecom_archive_messages m
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
