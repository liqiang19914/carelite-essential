-- 客户库「添加时间」改用企微侧真实添加时间
--
-- 此前列表显示的是本系统首次见到该客户的时间（first_seen_at），
-- 手动同步批量入库的历史好友全部显示同步时刻，用户误以为都是当天新增。
-- 新增 wecom_added_at 存企微 follow_info.createtime（回调 add 用事件 createtime），
-- 列表字段与排序改为 COALESCE(wecom_added_at, first_seen_at)。

ALTER TABLE public.merchant_wecom_contacts
  ADD COLUMN IF NOT EXISTS wecom_added_at timestamptz;

COMMENT ON COLUMN public.merchant_wecom_contacts.wecom_added_at IS '企微侧真实添加时间（同步 follow_info.createtime / 回调事件 createtime），空值回退 first_seen_at 展示';
CREATE OR REPLACE FUNCTION public.list_wecom_pro_contacts(p_keyword text DEFAULT NULL::text, p_follow_userid text DEFAULT NULL::text, p_tag_id text DEFAULT NULL::text, p_lost boolean DEFAULT NULL::boolean, p_linked boolean DEFAULT NULL::boolean, p_page integer DEFAULT 1, p_page_size integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
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
      COALESCE(c.wecom_added_at, c.first_seen_at) AS first_seen_at,
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
    ORDER BY COALESCE(c.wecom_added_at, c.first_seen_at) DESC NULLS LAST, c.id
    LIMIT LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100)
    OFFSET (GREATEST(COALESCE(p_page, 1), 1) - 1) * LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100)
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

NOTIFY pgrst, 'reload schema';
