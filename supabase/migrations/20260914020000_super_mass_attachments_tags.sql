-- 企微超级助手：群发附件（图片/视频/文件）+ 好友列表标签/设备筛选 + 每页条数放开到 200
-- 1) wecom_super_send_tasks.attachments：本次任务要随文本一起发的附件
--    [{kind:'image'|'video'|'file', url, name, size, width?, height?, duration?}]

-- ───────────────────────── 1. 附件列与发送进度列 ─────────────────────────
ALTER TABLE public.wecom_super_send_tasks
  ADD COLUMN IF NOT EXISTS attachments jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE public.wecom_super_send_items
  ADD COLUMN IF NOT EXISTS progress jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.wecom_super_send_tasks.attachments IS
  '随消息发送的附件：[{kind:image|video|file,url,name,size,...}]，cron 逐个上传协议商 CDN 后下发';
COMMENT ON COLUMN public.wecom_super_send_items.progress IS
  '多消息发送进度：{text:true,media:[true,false]}，断点续传防重发';

-- ───────────────────────── 2. 好友列表：设备 + 标签筛选，每页上限 200 ─────────────────────────
-- 参数签名变化（新增 p_device_guid / p_tag_ids），先删后建
DROP FUNCTION IF EXISTS public.list_wecom_super_contacts(text, int, int);

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
           c.synced_at AS "syncedAt"
    FROM public.wecom_super_contacts c
    WHERE c.root_manager_id = v_root
      AND (v_device IS NULL OR c.device_guid = v_device)
      AND (v_keyword IS NULL
           OR COALESCE(c.name, '') ILIKE '%' || v_keyword || '%'
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
              AND m.pro_external_userid = c.external_userid
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

-- ───────────────────────── 3. 群列表：每页上限 200 ─────────────────────────
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
         OR r.room_id ILIKE '%' || v_keyword || '%');

  SELECT COALESCE(jsonb_agg(to_jsonb(row)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT r.id, r.room_id AS "roomId", r.name, r.avatar_url AS "avatarUrl",
           r.member_count AS "memberCount", r.owner_id AS "ownerId",
           r.is_outer_room AS "isOuterRoom", r.device_guid AS "deviceGuid",
           r.synced_at AS "syncedAt"
    FROM public.wecom_super_rooms r
    WHERE r.root_manager_id = v_root
      AND (v_keyword IS NULL
           OR COALESCE(r.name, '') ILIKE '%' || v_keyword || '%'
           OR r.room_id ILIKE '%' || v_keyword || '%')
    ORDER BY r.synced_at DESC NULLS LAST, r.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_rooms(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_rooms(text, int, int) TO authenticated;

-- ───────────────────────── 4. 超级助手专用标签列表（不挂 Pro 模块闸门） ─────────────────────────
-- 与 Pro 标签共用 merchant_wecom_tags 三表，但只要求超级助手模块开通 + 管理员身份。
CREATE OR REPLACE FUNCTION public.list_wecom_super_tags()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'tagId', t.tag_id,
      'tagName', COALESCE(t.tag_name, t.tag_id),
      'groupId', t.group_id,
      'groupName', g.group_name,
      'sortOrder', t.sort_order
    ) ORDER BY g.sort_order, g.created_at, t.sort_order, t.created_at)
    FROM public.merchant_wecom_tags t
    LEFT JOIN public.merchant_wecom_tag_groups g
      ON g.root_manager_id = t.root_manager_id AND g.group_id = t.group_id
    WHERE t.root_manager_id = v_root
  ), '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_tags() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_tags() TO authenticated;
