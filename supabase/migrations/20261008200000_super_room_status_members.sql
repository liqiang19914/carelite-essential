-- 企微超级助手：群/成员软失效（留存不删除）+ 群成员列表 RPC + 九宫格头像素材
-- 1) rooms 增加 status(active|left)、left_at、member_synced_at
-- 2) room_members 增加 left_at（成员退群软标记）
-- 3) list_wecom_super_rooms 返回状态与前 9 个在群成员头像（前端拼九宫格群头像）
-- 4) 新增 list_wecom_super_room_members（点成员数查看群成员好友列表）

-- ───────────────────────── 1. rooms 软失效字段 ─────────────────────────
ALTER TABLE public.wecom_super_rooms
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active',  -- active 在群 | left 已退出/被移出
  ADD COLUMN IF NOT EXISTS left_at timestamptz,
  ADD COLUMN IF NOT EXISTS member_synced_at timestamptz;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'ck_wecom_super_rooms_status'
  ) THEN
    ALTER TABLE public.wecom_super_rooms
      ADD CONSTRAINT ck_wecom_super_rooms_status CHECK (status IN ('active', 'left'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_wecom_super_rooms_status
  ON public.wecom_super_rooms (root_manager_id, status, synced_at DESC);

-- ───────────────────────── 2. room_members 退群软标记 ─────────────────────────
ALTER TABLE public.wecom_super_room_members
  ADD COLUMN IF NOT EXISTS left_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_wecom_super_room_members_active
  ON public.wecom_super_room_members (root_manager_id, room_id)
  WHERE left_at IS NULL;

-- ───────────────────────── 3. 群列表 RPC：状态 + 九宫格头像素材 ─────────────────────────
DROP FUNCTION IF EXISTS public.list_wecom_super_rooms(text, int, int);

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
           r.member_count AS "memberCount", r.owner_id AS "ownerId",
           r.is_outer_room AS "isOuterRoom", r.device_guid AS "deviceGuid",
           r.synced_at AS "syncedAt", r.status,
           r.left_at AS "leftAt",
           r.member_synced_at AS "memberSyncedAt",
           COALESCE(r.remark_name, '') AS "remarkName",
           COALESCE(r.intro, '') AS "intro",
           COALESCE(r.ai_reply_enabled, true) AS "aiReplyEnabled",
           -- 前 9 个在群成员头像（有头像的在前），供前端拼九宫格群头像
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

-- ───────────────────────── 4. 群成员列表 RPC ─────────────────────────
CREATE OR REPLACE FUNCTION public.list_wecom_super_room_members(p_room_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
  v_room text := NULLIF(btrim(COALESCE(p_room_id, '')), '');
  v_owner text;
  v_items jsonb;
BEGIN
  IF v_room IS NULL THEN
    RAISE EXCEPTION '缺少群参数' USING ERRCODE = '22023';
  END IF;

  SELECT owner_id INTO v_owner
  FROM public.wecom_super_rooms
  WHERE root_manager_id = v_root AND room_id = v_room;

  SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row."isOwner" DESC, row."isAdmin" DESC, row."nickname" ASC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT rm.user_id AS "userId",
           COALESCE(NULLIF(rm.room_nick, ''), NULLIF(up.nickname, ''), rm.user_id) AS "displayName",
           NULLIF(rm.room_nick, '') AS "roomNick",
           NULLIF(up.nickname, '') AS "nickname",
           COALESCE(NULLIF(up.avatar_url, ''), '') AS "avatarUrl",
           rm.is_admin AS "isAdmin",
           (v_owner IS NOT NULL AND rm.user_id = v_owner) AS "isOwner",
           COALESCE(up.is_internal, false) AS "isCorp",
           rm.left_at AS "leftAt"
    FROM public.wecom_super_room_members rm
    LEFT JOIN public.wecom_super_user_profiles up
      ON up.root_manager_id = rm.root_manager_id AND up.user_id = rm.user_id
    WHERE rm.root_manager_id = v_root AND rm.room_id = v_room
    ORDER BY rm.left_at ASC NULLS FIRST
  ) row;

  RETURN jsonb_build_object(
    'items', v_items,
    'total', (SELECT count(*) FROM public.wecom_super_room_members
              WHERE root_manager_id = v_root AND room_id = v_room),
    'activeTotal', (SELECT count(*) FROM public.wecom_super_room_members
                    WHERE root_manager_id = v_root AND room_id = v_room AND left_at IS NULL),
    'ownerId', v_owner
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_room_members(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_room_members(text) TO authenticated;
