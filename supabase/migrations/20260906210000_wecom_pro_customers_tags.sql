-- 企微助手 Pro（SCRM 高级版）Task 2-4：
-- 1) merchant_wecom_contacts 预留流失列（Task 6 回调写入，本批列表先支持流失筛选）
-- 2) 企业标签三表：标签组 / 标签 / 客户-标签关联
-- 3) RPC：list_wecom_pro_contacts（客户库列表）、get_wecom_pro_contact_detail（客户画像）、
--    list_wecom_pro_tags（标签树）、list_wecom_pro_staff（承接员工筛选下拉）
-- 读取类 RPC 统一：模块双闸门（wecom_assistant_pro granted+enabled）+ 权限码 + 企业根收口；
-- 老板/管理员看全量，普通员工仅看自己承接（follow_userids 命中本人 wecom_userid）的客户。

-- ───────────────────────── 1. 好友表预留流失列 ─────────────────────────
ALTER TABLE public.merchant_wecom_contacts
  ADD COLUMN IF NOT EXISTS lost_at timestamptz,
  ADD COLUMN IF NOT EXISTS lost_userid text;

COMMENT ON COLUMN public.merchant_wecom_contacts.lost_at IS '客户流失（删除承接员工）时间；del_external_contact 回调写入，重新添加时清空';
COMMENT ON COLUMN public.merchant_wecom_contacts.lost_userid IS '被删除的承接员工企微 userid';

CREATE INDEX IF NOT EXISTS idx_wecom_contacts_root_first_seen
  ON public.merchant_wecom_contacts (root_manager_id, first_seen_at DESC);

-- ───────────────────────── 2. 企业标签三表 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.merchant_wecom_tag_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  group_id text NOT NULL,
  group_name text,
  sort_order int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_tag_group UNIQUE (root_manager_id, group_id)
);

CREATE TABLE IF NOT EXISTS public.merchant_wecom_tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  tag_id text NOT NULL,
  tag_name text,
  group_id text NOT NULL,
  sort_order int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_tag UNIQUE (root_manager_id, tag_id)
);

CREATE TABLE IF NOT EXISTS public.merchant_wecom_contact_tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  external_userid text NOT NULL,
  tag_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_contact_tag UNIQUE (root_manager_id, external_userid, tag_id)
);

CREATE INDEX IF NOT EXISTS idx_wecom_tags_root_group
  ON public.merchant_wecom_tags (root_manager_id, group_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_wecom_contact_tags_root_ext
  ON public.merchant_wecom_contact_tags (root_manager_id, external_userid);
CREATE INDEX IF NOT EXISTS idx_wecom_contact_tags_root_tag
  ON public.merchant_wecom_contact_tags (root_manager_id, tag_id);

ALTER TABLE public.merchant_wecom_tag_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.merchant_wecom_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.merchant_wecom_contact_tags ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.merchant_wecom_tag_groups FROM anon, authenticated;
REVOKE ALL ON public.merchant_wecom_tags FROM anon, authenticated;
REVOKE ALL ON public.merchant_wecom_contact_tags FROM anon, authenticated;

-- ───────────────────────── 3. 模块双闸门守卫（Pro RPC 复用） ─────────────────────────
CREATE OR REPLACE FUNCTION public.wecom_pro_module_open(p_root uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.merchant_module_grants
    WHERE manager_id = p_root
      AND module_key = 'wecom_assistant_pro'
      AND grant_status = 'granted'
      AND COALESCE(is_enabled, false)
  );
$function$;

REVOKE ALL ON FUNCTION public.wecom_pro_module_open(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.wecom_pro_module_open(uuid) TO authenticated;

-- ───────────────────────── 4. 客户库列表 ─────────────────────────
CREATE OR REPLACE FUNCTION public.list_wecom_pro_contacts(
  p_keyword text DEFAULT NULL,
  p_follow_userid text DEFAULT NULL,
  p_tag_id text DEFAULT NULL,
  p_lost boolean DEFAULT NULL,
  p_linked boolean DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_keyword text;
  v_follow text;
  v_tag_id text;
  v_is_admin boolean;
  v_my_userid text;
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
  IF NOT public.has_enterprise_permission('wecom_pro_customers', v_uid) THEN
    RAISE EXCEPTION '没有访问客户库的权限' USING ERRCODE = '42501';
  END IF;

  v_keyword := NULLIF(btrim(COALESCE(p_keyword, '')), '');
  v_follow := NULLIF(btrim(COALESCE(p_follow_userid, '')), '');
  v_tag_id := NULLIF(btrim(COALESCE(p_tag_id, '')), '');
  v_is_admin := public.is_enterprise_admin(v_uid);

  -- 普通员工强制只看自己承接的客户；未绑定企微 userid 的员工看不到任何客户
  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
    v_my_userid := COALESCE(btrim(COALESCE(v_my_userid, '')), '');
    IF v_my_userid = '' THEN
      RETURN jsonb_build_object('items', '[]'::jsonb, 'total', 0);
    END IF;
    v_follow := v_my_userid;
  END IF;

  SELECT count(*) INTO v_total
  FROM public.merchant_wecom_contacts c
  LEFT JOIN public.profiles p ON p.id = c.profile_id
  WHERE c.root_manager_id = v_root
    AND c.type = 'contact'
    AND (v_follow IS NULL OR c.follow_userids @> ARRAY[v_follow])
    AND (v_tag_id IS NULL OR EXISTS (
      SELECT 1 FROM public.merchant_wecom_contact_tags ct
      WHERE ct.root_manager_id = v_root
        AND ct.external_userid = c.external_userid
        AND ct.tag_id = v_tag_id
    ))
    AND (p_lost IS NULL OR (p_lost AND c.lost_at IS NOT NULL) OR (NOT p_lost AND c.lost_at IS NULL))
    AND (p_linked IS NULL OR (p_linked AND c.profile_id IS NOT NULL) OR (NOT p_linked AND c.profile_id IS NULL))
    AND (
      v_keyword IS NULL
      OR c.name ILIKE '%' || v_keyword || '%'
      OR c.external_userid ILIKE '%' || v_keyword || '%'
      OR COALESCE(p.nickname, '') ILIKE '%' || v_keyword || '%'
      OR COALESCE(p.phone, '') ILIKE '%' || v_keyword || '%'
    );

  SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row.first_seen_at DESC NULLS LAST, row.id), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      c.id,
      c.external_userid,
      c.type,
      COALESCE(c.name, c.external_userid) AS name,
      c.avatar_url,
      c.unionid,
      c.follow_userids,
      c.profile_id,
      p.nickname AS profile_nickname,
      p.phone AS profile_phone,
      c.source_state,
      c.first_seen_at,
      c.last_message_at,
      c.lost_at,
      c.lost_userid,
      COALESCE(
        (SELECT jsonb_agg(jsonb_build_object('wecomUserid', s.wecom_userid, 'nickname', s.nickname) ORDER BY s.nickname)
         FROM public.profiles s
         WHERE s.wecom_userid = ANY (c.follow_userids)),
        '[]'::jsonb
      ) AS follow_staff,
      COALESCE(
        (SELECT jsonb_agg(jsonb_build_object('tagId', t.tag_id, 'tagName', t.tag_name, 'groupId', t.group_id, 'sortOrder', t.sort_order) ORDER BY t.sort_order, t.tag_id)
         FROM public.merchant_wecom_contact_tags ct
         JOIN public.merchant_wecom_tags t
           ON t.root_manager_id = ct.root_manager_id AND t.tag_id = ct.tag_id
         WHERE ct.root_manager_id = v_root
           AND ct.external_userid = c.external_userid),
        '[]'::jsonb
      ) AS tags
    FROM public.merchant_wecom_contacts c
    LEFT JOIN public.profiles p ON p.id = c.profile_id
    WHERE c.root_manager_id = v_root
      AND c.type = 'contact'
      AND (v_follow IS NULL OR c.follow_userids @> ARRAY[v_follow])
      AND (v_tag_id IS NULL OR EXISTS (
        SELECT 1 FROM public.merchant_wecom_contact_tags ct
        WHERE ct.root_manager_id = v_root
          AND ct.external_userid = c.external_userid
          AND ct.tag_id = v_tag_id
      ))
      AND (p_lost IS NULL OR (p_lost AND c.lost_at IS NOT NULL) OR (NOT p_lost AND c.lost_at IS NULL))
      AND (p_linked IS NULL OR (p_linked AND c.profile_id IS NOT NULL) OR (NOT p_linked AND c.profile_id IS NULL))
      AND (
        v_keyword IS NULL
        OR c.name ILIKE '%' || v_keyword || '%'
        OR c.external_userid ILIKE '%' || v_keyword || '%'
        OR COALESCE(p.nickname, '') ILIKE '%' || v_keyword || '%'
        OR COALESCE(p.phone, '') ILIKE '%' || v_keyword || '%'
      )
    ORDER BY c.first_seen_at DESC NULLS LAST, c.id
    LIMIT LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100)
    OFFSET (GREATEST(COALESCE(p_page, 1), 1) - 1) * LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100)
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_pro_contacts(text, text, text, boolean, boolean, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_pro_contacts(text, text, text, boolean, boolean, int, int) TO authenticated;

-- ───────────────────────── 5. 客户画像详情 ─────────────────────────
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

  -- 员工只能看自己承接的客户
  v_is_admin := public.is_enterprise_admin(v_uid);
  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
    IF COALESCE(btrim(COALESCE(v_my_userid, '')), '') = ''
       OR NOT (v_contact.follow_userids @> ARRAY[btrim(v_my_userid)]) THEN
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

  -- 跟进时间线：先做加好友 / 流失事件（回调事件表）
  v_timeline := COALESCE(
    (SELECT jsonb_agg(jsonb_build_object(
       'type', CASE ev.payload->>'ChangeType'
                 WHEN 'add_external_contact' THEN 'add_friend'
                 WHEN 'del_external_contact' THEN 'lost'
                 ELSE (ev.payload->>'ChangeType')
               END,
       'operator', ev.payload->>'FromUserID',
       'state', ev.payload->>'State',
       'eventTime', CASE
         WHEN ev.wecom_create_time IS NOT NULL
           THEN to_timestamp(ev.wecom_create_time)
         ELSE ev.created_at
       END
     ) ORDER BY ev.created_at ASC)
     FROM public.merchant_wecom_events ev
     WHERE ev.root_manager_id = v_root
       AND ev.event_type = 'change_external_contact'
       AND ev.payload->>'ExternalUserID' = v_contact.external_userid
       AND ev.payload->>'ChangeType' IN ('add_external_contact', 'del_external_contact')),
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

-- ───────────────────────── 6. 标签树（客户库与标签管理共用） ─────────────────────────
CREATE OR REPLACE FUNCTION public.list_wecom_pro_tags()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
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
  -- 客户库与标签管理两个菜单都要展示标签
  IF NOT (
    public.has_enterprise_permission('wecom_pro_tags', v_uid)
    OR public.has_enterprise_permission('wecom_pro_customers', v_uid)
  ) THEN
    RAISE EXCEPTION '没有访问标签的权限' USING ERRCODE = '42501';
  END IF;

  RETURN COALESCE(
    (
      SELECT jsonb_agg(
        jsonb_build_object(
          'groupId', g.group_id,
          'groupName', g.group_name,
          'sortOrder', g.sort_order,
          'tags', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'tagId', t.tag_id,
              'tagName', t.tag_name,
              'groupId', t.group_id,
              'sortOrder', t.sort_order
            ) ORDER BY t.sort_order, t.created_at)
            FROM public.merchant_wecom_tags t
            WHERE t.root_manager_id = g.root_manager_id AND t.group_id = g.group_id
          ), '[]'::jsonb)
        ) ORDER BY g.sort_order, g.created_at
      )
      FROM public.merchant_wecom_tag_groups g
      WHERE g.root_manager_id = v_root
    ),
    '[]'::jsonb
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_pro_tags() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_pro_tags() TO authenticated;

-- ───────────────────────── 7. 承接员工筛选下拉（已绑定企微的成员） ─────────────────────────
CREATE OR REPLACE FUNCTION public.list_wecom_pro_staff()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
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

  RETURN COALESCE(
    (
      SELECT jsonb_agg(jsonb_build_object(
        'id', p.id,
        'nickname', p.nickname,
        'wecomUserid', p.wecom_userid
      ) ORDER BY p.nickname)
      FROM public.profiles p
      WHERE (p.id = v_root OR p.parent_manager_id = v_root)
        AND p.role = 'manager'
        AND COALESCE(p.is_disabled, false) = false
        AND COALESCE(btrim(COALESCE(p.wecom_userid, '')), '') <> ''
    ),
    '[]'::jsonb
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_pro_staff() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_pro_staff() TO authenticated;
