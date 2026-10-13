-- 客户群：列表返回前 4 个成员头像；详情头像加客户画像 fallback

-- ── list_wecom_pro_chat_groups 重建 ──
CREATE OR REPLACE FUNCTION public.list_wecom_pro_chat_groups(
  p_keyword text DEFAULT NULL,
  p_owner_userid text DEFAULT NULL,
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
  IF NOT public.has_enterprise_permission('wecom_pro_groups', v_uid) THEN
    RAISE EXCEPTION '没有访问客户群的权限' USING ERRCODE = '42501';
  END IF;

  v_keyword := NULLIF(btrim(COALESCE(p_keyword, '')), '');
  v_is_admin := public.is_enterprise_admin(v_uid);

  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
    v_my_userid := NULLIF(btrim(COALESCE(v_my_userid, '')), '');
    IF v_my_userid IS NULL THEN
      RETURN jsonb_build_object('items', '[]'::jsonb, 'total', 0);
    END IF;
  END IF;

  SELECT count(*) INTO v_total
  FROM public.merchant_wecom_chat_groups g
  WHERE g.root_manager_id = v_root
    AND (v_keyword IS NULL OR g.name ILIKE '%' || v_keyword || '%')
    AND (p_owner_userid IS NULL OR g.owner_userid = p_owner_userid)
    AND (
      v_is_admin
      OR EXISTS (
        SELECT 1 FROM public.merchant_wecom_chat_group_members m
        WHERE m.root_manager_id = v_root AND m.chat_id = g.chat_id AND m.member_id = v_my_userid
      )
    );

  SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row.updated_at DESC NULLS LAST, row.name), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT g.id, g.chat_id, g.name, g.owner_userid, g.member_count, g.notice,
           g.created_at, g.updated_at,
           COALESCE((SELECT p.nickname FROM public.profiles p WHERE p.wecom_userid = g.owner_userid AND COALESCE(p.parent_manager_id, p.id) = v_root LIMIT 1), '') AS owner_name,
           -- 前 4 个成员的头像（用于群图标 2×2 拼贴）
           (SELECT ARRAY(
             SELECT av.url FROM (
               SELECT DISTINCT ON (mm.member_id) COALESCE(
                 CASE WHEN mm.member_type = 'external' THEN
                   (SELECT c.avatar_url FROM public.merchant_wecom_contacts c
                     WHERE c.root_manager_id = v_root AND c.external_userid = mm.member_id AND c.avatar_url IS NOT NULL AND c.avatar_url <> '' LIMIT 1)
                 END,
                 CASE WHEN mm.member_type = 'member' THEN
                   (SELECT p.avatar_url FROM public.profiles p
                     WHERE p.wecom_userid = mm.member_id AND COALESCE(p.parent_manager_id, p.id) = v_root AND p.avatar_url IS NOT NULL AND p.avatar_url <> '' LIMIT 1)
                 END,
                 ''
               ) AS url
               FROM public.merchant_wecom_chat_group_members mm
               WHERE mm.root_manager_id = v_root AND mm.chat_id = g.chat_id
               ORDER BY mm.member_id
             ) av WHERE av.url IS NOT NULL AND av.url <> '' LIMIT 4
           )) AS avatars
    FROM public.merchant_wecom_chat_groups g
    WHERE g.root_manager_id = v_root
      AND (v_keyword IS NULL OR g.name ILIKE '%' || v_keyword || '%')
      AND (p_owner_userid IS NULL OR g.owner_userid = p_owner_userid)
      AND (
        v_is_admin
        OR EXISTS (
          SELECT 1 FROM public.merchant_wecom_chat_group_members m
          WHERE m.root_manager_id = v_root AND m.chat_id = g.chat_id AND m.member_id = v_my_userid
        )
      )
    ORDER BY g.updated_at DESC NULLS LAST, g.name
    LIMIT LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100)
    OFFSET (GREATEST(COALESCE(p_page, 1), 1) - 1) * LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100)
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_pro_chat_groups(text, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_pro_chat_groups(text, text, int, int) TO authenticated;


-- ── get_wecom_pro_chat_group_detail 重建（头像加客户画像 fallback）──
CREATE OR REPLACE FUNCTION public.get_wecom_pro_chat_group_detail(p_chat_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_is_admin boolean;
  v_my_userid text;
  v_group public.merchant_wecom_chat_groups%ROWTYPE;
  v_members jsonb;
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
  IF NOT public.has_enterprise_permission('wecom_pro_groups', v_uid) THEN
    RAISE EXCEPTION '没有访问客户群的权限' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_group
  FROM public.merchant_wecom_chat_groups
  WHERE root_manager_id = v_root AND chat_id = btrim(COALESCE(p_chat_id, ''));
  IF v_group.id IS NULL THEN
    RAISE EXCEPTION '群不存在或无权查看' USING ERRCODE = '42501';
  END IF;

  v_is_admin := public.is_enterprise_admin(v_uid);
  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
    v_my_userid := NULLIF(btrim(COALESCE(v_my_userid, '')), '');
    IF v_my_userid IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.merchant_wecom_chat_group_members m
      WHERE m.root_manager_id = v_root AND m.chat_id = v_group.chat_id AND m.member_id = v_my_userid
    ) THEN
      RAISE EXCEPTION '群不存在或无权查看' USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'memberId', m.member_id,
    'memberType', m.member_type,
    'name', m.name,
    'unionid', m.unionid,
    'joinedAt', m.joined_at,
    -- 头像：外部成员 contact.avatar_url → profile.avatar_url；企业成员 profiles.avatar_url
    'avatarUrl', COALESCE(
      CASE WHEN m.member_type = 'external' THEN
        COALESCE(
          (SELECT c.avatar_url FROM public.merchant_wecom_contacts c
            WHERE c.root_manager_id = v_root AND c.external_userid = m.member_id AND c.avatar_url IS NOT NULL AND c.avatar_url <> '' LIMIT 1),
          (SELECT p.avatar_url FROM public.profiles p
            JOIN public.merchant_wecom_contacts c ON c.profile_id = p.id
            WHERE c.root_manager_id = v_root AND c.external_userid = m.member_id
              AND p.avatar_url IS NOT NULL AND p.avatar_url <> '' LIMIT 1)
        )
      END,
      CASE WHEN m.member_type = 'member' THEN
        (SELECT p.avatar_url FROM public.profiles p
          WHERE p.wecom_userid = m.member_id
            AND COALESCE(p.parent_manager_id, p.id) = v_root AND p.avatar_url IS NOT NULL AND p.avatar_url <> '' LIMIT 1)
      END,
      ''
    ),
    'contactName', CASE WHEN m.member_type = 'external' THEN
      COALESCE((SELECT c.name FROM public.merchant_wecom_contacts c
        WHERE c.root_manager_id = v_root AND c.external_userid = m.member_id LIMIT 1), m.name)
    ELSE '' END
  ) ORDER BY (m.member_type = 'external'), m.name NULLS LAST), '[]'::jsonb) INTO v_members
  FROM public.merchant_wecom_chat_group_members m
  WHERE m.root_manager_id = v_root AND m.chat_id = v_group.chat_id;

  RETURN jsonb_build_object(
    'id', v_group.id,
    'chatId', v_group.chat_id,
    'name', v_group.name,
    'ownerUserid', v_group.owner_userid,
    'memberCount', v_group.member_count,
    'notice', v_group.notice,
    'createdAt', v_group.created_at,
    'updatedAt', v_group.updated_at,
    'members', v_members
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_wecom_pro_chat_group_detail(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wecom_pro_chat_group_detail(text) TO authenticated;
