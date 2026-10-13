-- ============================================================================
-- 企微助手 Pro —— Task 5/6：渠道活码自动打标 + 客户流失提醒
--
-- 变更概览：
--   1) merchant_wecom_contact_ways 加列 auto_tag_ids（活码渠道自动打标规则，本地规则不传企微）
--   2) 替换 list_merchant_wecom_contact_ways()：返回 auto_tag_ids
--   3) 新建 get_wecom_pro_contact_stats()：总客户 / 今日新增 / 今日流失（员工仅本人口径）
--   4) 替换 get_wecom_pro_contact_detail()：时间线修正成员字段（UserID），并入「打标签」记录
--
-- 约定：所有 RPC 走 SECURITY DEFINER + SET search_path = ''；Pro 读取统一
--       wecom_pro_module_open(root) 双闸门 + has_enterprise_permission 权限码收口。
-- ============================================================================

-- ───────────────────────── 1. 活码自动打标规则列 ─────────────────────────
ALTER TABLE public.merchant_wecom_contact_ways
  ADD COLUMN IF NOT EXISTS auto_tag_ids text[] NOT NULL DEFAULT '{}';

COMMENT ON COLUMN public.merchant_wecom_contact_ways.auto_tag_ids IS
  '渠道活码自动打标规则：客户经此活码添加好友后，回调自动打上的企微企业标签 tag_id 列表（Pro 功能，未开通商户不生效）';

-- ───────────────────────── 2. 活码列表 RPC（透传 auto_tag_ids） ─────────────────────────
CREATE OR REPLACE FUNCTION public.list_merchant_wecom_contact_ways()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_items jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(w) ORDER BY w.created_at DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT id, config_id, qr_code, remark, state, userids, auto_tag_ids,
           type, scene, status, created_at, updated_at
    FROM public.merchant_wecom_contact_ways
    WHERE root_manager_id = v_root
      AND status = 'active'
  ) w;

  RETURN jsonb_build_object('items', v_items);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_merchant_wecom_contact_ways() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_merchant_wecom_contact_ways() TO authenticated;

-- ───────────────────────── 3. 客户库统计（总客户 / 今日新增 / 今日流失） ─────────────────────────
CREATE OR REPLACE FUNCTION public.get_wecom_pro_contact_stats()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_is_admin boolean;
  v_my_userid text;
  v_tz text;
  v_day_start timestamptz;
  v_total int;
  v_added int;
  v_lost int;
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
  IF NOT public.has_enterprise_permission('wecom_pro_customers', v_uid) THEN
    RAISE EXCEPTION '没有访问客户库的权限' USING ERRCODE = '42501';
  END IF;

  v_is_admin := public.is_enterprise_admin(v_uid);
  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
  END IF;
  v_my_userid := btrim(COALESCE(v_my_userid, ''));

  -- 「今日」按商户时区切日（企微定时推送设置里的 timezone，缺省 Asia/Shanghai）
  SELECT timezone INTO v_tz
  FROM public.merchant_wecom_settings
  WHERE root_manager_id = v_root;
  v_tz := COALESCE(NULLIF(btrim(COALESCE(v_tz, '')), ''), 'Asia/Shanghai');
  v_day_start := date_trunc('day', now() AT TIME ZONE v_tz) AT TIME ZONE v_tz;

  SELECT
    count(*)::int,
    count(*) FILTER (WHERE c.first_seen_at >= v_day_start)::int,
    count(*) FILTER (WHERE c.lost_at >= v_day_start)::int
  INTO v_total, v_added, v_lost
  FROM public.merchant_wecom_contacts c
  WHERE c.root_manager_id = v_root
    AND c.type = 'contact'
    AND (
      v_is_admin
      OR (
        v_my_userid <> ''
        AND (v_my_userid = ANY (c.follow_userids) OR c.lost_userid = v_my_userid)
      )
    );

  RETURN jsonb_build_object(
    'total', COALESCE(v_total, 0),
    'todayAdded', COALESCE(v_added, 0),
    'todayLost', COALESCE(v_lost, 0)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_wecom_pro_contact_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wecom_pro_contact_stats() TO authenticated;

-- ───────────────────────── 4. 客户详情：时间线修正 + 打标签记录 ─────────────────────────
-- 替换 Task 2-4 迁移中的同名函数：成员字段企微事件实际为 UserID（原取 FromUserID 永远为空），
-- 时间线并入 contact_tags 的打标记录（含渠道自动打标与手动打标）。
CREATE OR REPLACE FUNCTION public.get_wecom_pro_contact_detail(p_external_userid text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_is_admin boolean;
  v_my_userid text;
  v_contact public.merchant_wecom_contacts;
  v_profile jsonb;
  v_timeline jsonb;
  v_tags jsonb;
  v_follow_staff jsonb;
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
  IF NOT public.has_enterprise_permission('wecom_pro_customers', v_uid) THEN
    RAISE EXCEPTION '没有访问客户库的权限' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_contact
  FROM public.merchant_wecom_contacts
  WHERE root_manager_id = v_root AND external_userid = btrim(COALESCE(p_external_userid, ''));
  IF v_contact.id IS NULL THEN
    RAISE EXCEPTION '客户不存在或无权查看' USING ERRCODE = '42501';
  END IF;

  -- 员工只能看自己承接的客户（流失客户 follow_userids 已清空，用 lost_userid 兜底）
  v_is_admin := public.is_enterprise_admin(v_uid);
  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
    IF COALESCE(btrim(COALESCE(v_my_userid, '')), '') = ''
       OR NOT (
         v_contact.follow_userids @> ARRAY[btrim(v_my_userid)]
         OR v_contact.lost_userid = btrim(v_my_userid)
       ) THEN
      RAISE EXCEPTION '客户不存在或无权查看' USING ERRCODE = '42501';
    END IF;
  END IF;

  v_follow_staff := COALESCE(
    (SELECT jsonb_agg(jsonb_build_object('wecomUserid', s.wecom_userid, 'nickname', s.nickname) ORDER BY s.nickname)
     FROM public.profiles s
     WHERE s.wecom_userid = ANY (v_contact.follow_userids)),
    '[]'::jsonb
  );

  v_tags := COALESCE(
    (SELECT jsonb_agg(jsonb_build_object('tagId', t.tag_id, 'tagName', t.tag_name, 'groupId', t.group_id) ORDER BY t.sort_order, t.tag_id)
     FROM public.merchant_wecom_contact_tags ct
     JOIN public.merchant_wecom_tags t
       ON t.root_manager_id = ct.root_manager_id AND t.tag_id = ct.tag_id
     WHERE ct.root_manager_id = v_root
       AND ct.external_userid = v_contact.external_userid),
    '[]'::jsonb
  );

  -- 关联系统客户摘要：姓名 / 手机 / 归属健管师 / 最近一次体成分记录
  IF v_contact.profile_id IS NOT NULL THEN
    v_profile := (
      SELECT jsonb_build_object(
        'id', pr.id,
        'nickname', pr.nickname,
        'phone', pr.phone,
        'healthManagerNickname', hm.nickname,
        'latestWeighing', (
          SELECT jsonb_build_object('measuredAt', bc.measured_at, 'weight', bc.weight, 'bmi', bc.bmi)
          FROM public.body_compositions bc
          JOIN public.health_records hr ON hr.id = bc.record_id
          WHERE hr.user_id = pr.id
          ORDER BY bc.measured_at DESC
          LIMIT 1
        )
      )
      FROM public.profiles pr
      LEFT JOIN LATERAL (
        SELECT p2.nickname
        FROM public.client_relations cr
        JOIN public.profiles p2 ON p2.id = cr.manager_id
        WHERE cr.client_id = pr.id AND cr.status = 'active'
        ORDER BY cr.created_at DESC
        LIMIT 1
      ) hm ON true
      WHERE pr.id = v_contact.profile_id
    );
  ELSE
    v_profile := NULL;
  END IF;

  -- 跟进时间线：加好友 / 流失回调事件 + 打标签记录（渠道自动打标与手动打标），按时间正序
  v_timeline := COALESCE(
    (SELECT jsonb_agg(sub.item ORDER BY (sub.item->>'eventTime') ASC, sub.item->>'type' ASC)
     FROM (
       SELECT jsonb_build_object(
          'type', CASE ev.payload->>'ChangeType'
                    WHEN 'add_external_contact' THEN 'add_friend'
                    WHEN 'del_external_contact' THEN 'lost'
                    ELSE (ev.payload->>'ChangeType')
                  END,
          'operator', COALESCE(
            (SELECT s.nickname FROM public.profiles s
             WHERE s.wecom_userid = COALESCE(ev.payload->>'UserID', ev.payload->>'FromUserID')
               AND COALESCE(s.parent_manager_id, s.id) = v_root
             LIMIT 1),
            COALESCE(ev.payload->>'UserID', ev.payload->>'FromUserID')
          ),
          'state', ev.payload->>'State',
          'tagName', NULL,
          'eventTime', CASE
            WHEN ev.wecom_create_time IS NOT NULL THEN to_timestamp(ev.wecom_create_time)
            ELSE ev.created_at
          END
        ) AS item
        FROM public.merchant_wecom_events ev
        WHERE ev.root_manager_id = v_root
          AND ev.event_type = 'change_external_contact'
          AND ev.payload->>'ExternalUserID' = v_contact.external_userid
          AND ev.payload->>'ChangeType' IN ('add_external_contact', 'del_external_contact')
       UNION ALL
       SELECT jsonb_build_object(
          'type', 'tag_added',
          'operator', NULL,
          'state', NULL,
          'tagName', t.tag_name,
          'eventTime', ct.created_at
        ) AS item
        FROM public.merchant_wecom_contact_tags ct
        JOIN public.merchant_wecom_tags t
          ON t.root_manager_id = ct.root_manager_id AND t.tag_id = ct.tag_id
        WHERE ct.root_manager_id = v_root
          AND ct.external_userid = v_contact.external_userid
     ) sub),
    '[]'::jsonb
  );

  RETURN jsonb_build_object(
    'contact', jsonb_build_object(
      'id', v_contact.id,
      'externalUserid', v_contact.external_userid,
      'type', v_contact.type,
      'name', COALESCE(v_contact.name, v_contact.external_userid),
      'avatarUrl', v_contact.avatar_url,
      'unionid', v_contact.unionid,
      'followUserids', to_jsonb(v_contact.follow_userids),
      'profileId', v_contact.profile_id,
      'sourceState', v_contact.source_state,
      'firstSeenAt', v_contact.first_seen_at,
      'lastMessageAt', v_contact.last_message_at,
      'lostAt', v_contact.lost_at,
      'lostUserid', v_contact.lost_userid,
      'followStaff', v_follow_staff,
      'tags', v_tags
    ),
    'profile', v_profile,
    'timeline', v_timeline
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_wecom_pro_contact_detail(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wecom_pro_contact_detail(text) TO authenticated;
