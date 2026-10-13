-- 群列表 memberCount 改为从 wecom_super_room_members 实时统计，避免冗余字段不同步
DROP FUNCTION IF EXISTS public.list_wecom_super_rooms(text, int, int, boolean);

CREATE OR REPLACE FUNCTION public.list_wecom_super_rooms(
  p_keyword text DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 20,
  p_include_left boolean DEFAULT false
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
    AND (COALESCE(p_include_left, false) OR r.status = 'active')
    AND (v_keyword IS NULL
         OR COALESCE(r.name, '') ILIKE '%' || v_keyword || '%'
         OR COALESCE(r.remark_name, '') ILIKE '%' || v_keyword || '%'
         OR r.room_id ILIKE '%' || v_keyword || '%');

  SELECT COALESCE(jsonb_agg(to_jsonb(row)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT r.id, r.room_id AS "roomId", r.name, r.avatar_url AS "avatarUrl",
           -- 从成员表实时统计在群人数（left_at IS NULL），不再依赖冗余 member_count 字段
           (SELECT count(*) FROM public.wecom_super_room_members rm
            WHERE rm.root_manager_id = r.root_manager_id
              AND rm.room_id = r.room_id AND rm.left_at IS NULL)::int AS "memberCount",
           r.owner_id AS "ownerId",
           r.is_outer_room AS "isOuterRoom", r.device_guid AS "deviceGuid",
           r.synced_at AS "syncedAt", r.status,
           r.left_at AS "leftAt",
           r.member_synced_at AS "memberSyncedAt",
           COALESCE(r.remark_name, '') AS "remarkName",
           COALESCE(r.intro, '') AS "intro",
           COALESCE(r.ai_reply_enabled, true) AS "aiReplyEnabled",
           COALESCE((
             SELECT jsonb_agg(up.avatar_url)
             FROM (
               SELECT up.avatar_url
               FROM public.wecom_super_room_members rm
               JOIN public.wecom_super_user_profiles up
                 ON up.root_manager_id = rm.root_manager_id AND up.user_id = rm.user_id
               WHERE rm.root_manager_id = r.root_manager_id
                 AND rm.room_id = r.room_id AND rm.left_at IS NULL
                 AND COALESCE(up.avatar_url, '') <> ''
               ORDER BY rm.is_admin DESC, rm.synced_at DESC
               LIMIT 9
             ) up
           ), '[]'::jsonb) AS "memberAvatars"
    FROM public.wecom_super_rooms r
    WHERE r.root_manager_id = v_root
      AND (COALESCE(p_include_left, false) OR r.status = 'active')
      AND (v_keyword IS NULL
           OR COALESCE(r.name, '') ILIKE '%' || v_keyword || '%'
           OR COALESCE(r.remark_name, '') ILIKE '%' || v_keyword || '%'
           OR r.room_id ILIKE '%' || v_keyword || '%')
    ORDER BY r.status ASC, r.synced_at DESC NULLS LAST, r.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_rooms(text, int, int, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_rooms(text, int, int, boolean) TO authenticated;
