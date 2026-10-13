-- 企微超级助手（第三方 iPad 协议外挂模块）Task 1：
-- 平台配置 / 商户配置 / 设备 / 好友 / 群 / 消息 / 发送任务+明细 / AI 建议 共 8 表；
-- 全部 RLS 收口 + REVOKE，前端读取走 SECURITY DEFINER RPC（模块闸门 wecom_super_module_open）；
-- 写入一律由 Edge Function（SUPABASE_DB_URL 服务端直连）完成，Token 永不下发前端。
-- 模块 key：wecom_super_assistant（merchant_module_grants）。

-- ───────────────────────── 1. 平台级配置（单行） ─────────────────────────
CREATE TABLE IF NOT EXISTS public.wecom_super_platform_config (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  platform_token text,
  token_enabled boolean NOT NULL DEFAULT false,
  default_seat_quota int NOT NULL DEFAULT 1,
  rate_limit_interval_sec int NOT NULL DEFAULT 8,
  daily_send_cap int NOT NULL DEFAULT 200,
  ai_daily_cap int NOT NULL DEFAULT 30,
  callback_url text,
  callback_secret text,
  updated_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.wecom_super_platform_config (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- ───────────────────────── 2. 商户配置 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.wecom_super_merchant_config (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL UNIQUE REFERENCES public.managers(id) ON DELETE CASCADE,
  token_source text NOT NULL DEFAULT 'platform',          -- platform | own
  own_token text,                                          -- 商户自填 Qiwe Token（仅服务端读取）
  seat_quota int,                                          -- 平台分配坐席数；NULL 用平台默认
  risk_ack_at timestamptz,                                 -- 风险提示确认时间
  ai_enabled boolean NOT NULL DEFAULT false,
  ai_mode text NOT NULL DEFAULT 'manual',                  -- manual（审核发送）| auto（免审核）
  ai_daily_cap int NOT NULL DEFAULT 10,
  ai_per_client_cap int NOT NULL DEFAULT 1,                -- 每客户 7 天内 AI 触达上限
  settings jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT wecom_super_token_source_chk CHECK (token_source IN ('platform', 'own')),
  CONSTRAINT wecom_super_ai_mode_chk CHECK (ai_mode IN ('manual', 'auto'))
);

-- ───────────────────────── 3. 设备（iPad 云设备） ─────────────────────────
CREATE TABLE IF NOT EXISTS public.wecom_super_devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  guid text NOT NULL,
  device_name text NOT NULL,
  area_code text,
  area_name text,
  status text NOT NULL DEFAULT 'creating',
  -- creating | waiting_qr | scanned | confirming | online | offline | kicked | logout | expired | failed
  qr_key text,
  qr_base64 text,
  login_userid text,
  login_nickname text,
  login_corpid text,
  login_corp_name text,
  avatar_url text,
  last_event_at timestamptz,
  last_error text,
  raw jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_super_device_guid UNIQUE (root_manager_id, guid)
);

CREATE INDEX IF NOT EXISTS idx_wecom_super_devices_root
  ON public.wecom_super_devices (root_manager_id, status);
-- 回调反查：guid 全局唯一（一个 Token 内），不带 root 以便回调快速定位
CREATE UNIQUE INDEX IF NOT EXISTS uq_wecom_super_devices_guid_global
  ON public.wecom_super_devices (guid);

-- ───────────────────────── 4. 好友 / 外部联系人 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.wecom_super_contacts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  device_guid text,
  external_userid text NOT NULL,                          -- Qiwe 侧 userId / wxid
  name text,
  avatar_url text,
  contact_type text NOT NULL DEFAULT 'external',           -- external | internal
  account text,
  gender int,
  raw jsonb NOT NULL DEFAULT '{}'::jsonb,
  synced_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_super_contact UNIQUE (root_manager_id, external_userid)
);

CREATE INDEX IF NOT EXISTS idx_wecom_super_contacts_root
  ON public.wecom_super_contacts (root_manager_id, synced_at DESC);

-- ───────────────────────── 5. 群聊 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.wecom_super_rooms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  device_guid text,
  room_id text NOT NULL,                                   -- Qiwe 侧 roomId / chatroomId
  name text,
  avatar_url text,
  member_count int NOT NULL DEFAULT 0,
  owner_id text,
  is_outer_room boolean,
  raw jsonb NOT NULL DEFAULT '{}'::jsonb,
  synced_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_super_room UNIQUE (root_manager_id, room_id)
);

CREATE INDEX IF NOT EXISTS idx_wecom_super_rooms_root
  ON public.wecom_super_rooms (root_manager_id, synced_at DESC);

-- ───────────────────────── 6. 消息（回调落库 + 主动发送落库） ─────────────────────────
CREATE TABLE IF NOT EXISTS public.wecom_super_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  device_guid text,
  seq bigint,                                              -- 回调 seq，去重用；主动发送为 NULL
  direction text NOT NULL DEFAULT 'in',                    -- in | out
  msg_type text NOT NULL DEFAULT 'text',                   -- text | image | ...
  peer_id text NOT NULL,                                   -- 会话归属：群 room_id 或好友 userId
  peer_type text NOT NULL DEFAULT 'contact',               -- contact | room
  from_id text,
  to_id text,
  room_id text,
  sender_name text,
  content_text text,
  content_raw jsonb NOT NULL DEFAULT '{}'::jsonb,
  msg_server_id text,
  task_id uuid,
  msg_time timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT wecom_super_msg_dir_chk CHECK (direction IN ('in', 'out')),
  CONSTRAINT wecom_super_msg_peer_chk CHECK (peer_type IN ('contact', 'room')),
  CONSTRAINT uq_wecom_super_msg_seq UNIQUE (root_manager_id, device_guid, seq)
);

CREATE INDEX IF NOT EXISTS idx_wecom_super_messages_peer
  ON public.wecom_super_messages (root_manager_id, peer_id, msg_time DESC);
CREATE INDEX IF NOT EXISTS idx_wecom_super_messages_root_time
  ON public.wecom_super_messages (root_manager_id, msg_time DESC);

-- ───────────────────────── 7. 发送任务 + 明细 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.wecom_super_send_tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  created_by uuid,
  kind text NOT NULL DEFAULT 'private_mass',
  -- single | private_mass | group_mass | ai_manual | ai_auto
  target_type text NOT NULL DEFAULT 'contact',             -- contact | room
  device_guid text,
  content text NOT NULL DEFAULT '',
  targets jsonb NOT NULL DEFAULT '[]'::jsonb,              -- ["userId/roomId", ...]
  scheduled_at timestamptz,
  status text NOT NULL DEFAULT 'draft',
  -- draft | scheduled | sending | done | partial | failed | cancelled
  total_count int NOT NULL DEFAULT 0,
  sent_count int NOT NULL DEFAULT 0,
  fail_count int NOT NULL DEFAULT 0,
  last_error text,
  result jsonb NOT NULL DEFAULT '{}'::jsonb,
  approved_by uuid,
  approved_at timestamptz,
  ai_suggestion_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT wecom_super_task_kind_chk CHECK (kind IN
    ('single', 'private_mass', 'group_mass', 'ai_manual', 'ai_auto')),
  CONSTRAINT wecom_super_task_status_chk CHECK (status IN
    ('draft', 'scheduled', 'sending', 'done', 'partial', 'failed', 'cancelled'))
);

CREATE INDEX IF NOT EXISTS idx_wecom_super_tasks_root
  ON public.wecom_super_send_tasks (root_manager_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wecom_super_tasks_due
  ON public.wecom_super_send_tasks (status, scheduled_at);

CREATE TABLE IF NOT EXISTS public.wecom_super_send_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES public.wecom_super_send_tasks(id) ON DELETE CASCADE,
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  target_id text NOT NULL,
  status text NOT NULL DEFAULT 'pending',                  -- pending | sent | failed
  msg_server_id text,
  error text,
  sent_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_super_send_item UNIQUE (task_id, target_id)
);

CREATE INDEX IF NOT EXISTS idx_wecom_super_send_items_task
  ON public.wecom_super_send_items (task_id, status);

-- ───────────────────────── 8. AI 营销建议 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.wecom_super_ai_suggestions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  client_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  client_name text,
  device_guid text,
  target_id text NOT NULL,                                 -- 发送对象 userId
  context jsonb NOT NULL DEFAULT '{}'::jsonb,              -- 称重/对话上下文摘要
  suggested_content text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'pending',
  -- pending | approved | rejected | sent | auto_sent | failed
  task_id uuid,
  handled_by uuid,
  handled_at timestamptz,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT wecom_super_ai_status_chk CHECK (status IN
    ('pending', 'approved', 'rejected', 'sent', 'auto_sent', 'failed'))
);

CREATE INDEX IF NOT EXISTS idx_wecom_super_ai_root_status
  ON public.wecom_super_ai_suggestions (root_manager_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wecom_super_ai_client
  ON public.wecom_super_ai_suggestions (root_manager_id, client_id, created_at DESC);

-- ───────────────────────── 9. RLS 收口 ─────────────────────────
ALTER TABLE public.wecom_super_platform_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wecom_super_merchant_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wecom_super_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wecom_super_contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wecom_super_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wecom_super_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wecom_super_send_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wecom_super_send_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wecom_super_ai_suggestions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.wecom_super_platform_config FROM anon, authenticated;
REVOKE ALL ON public.wecom_super_merchant_config FROM anon, authenticated;
REVOKE ALL ON public.wecom_super_devices FROM anon, authenticated;
REVOKE ALL ON public.wecom_super_contacts FROM anon, authenticated;
REVOKE ALL ON public.wecom_super_rooms FROM anon, authenticated;
REVOKE ALL ON public.wecom_super_messages FROM anon, authenticated;
REVOKE ALL ON public.wecom_super_send_tasks FROM anon, authenticated;
REVOKE ALL ON public.wecom_super_send_items FROM anon, authenticated;
REVOKE ALL ON public.wecom_super_ai_suggestions FROM anon, authenticated;

-- ───────────────────────── 10. 模块闸门 ─────────────────────────
-- 模块白名单 CHECK 扩展：新增 wecom_super_assistant
ALTER TABLE public.merchant_module_grants DROP CONSTRAINT IF EXISTS mmg_module_key_check;
ALTER TABLE public.merchant_module_grants ADD CONSTRAINT mmg_module_key_check
CHECK (module_key = ANY (ARRAY[
  'shop_order_lifecycle', 'points_exchange', 'stores',
  'view_conversations', 'view_health_insights', 'view_health_records',
  'native_login', 'marketing_center', 'wecom_assistant_pro',
  'wecom_super_assistant'
]::text[]));
CREATE OR REPLACE FUNCTION public.wecom_super_module_open(p_root uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.merchant_module_grants
    WHERE manager_id = p_root
      AND module_key = 'wecom_super_assistant'
      AND grant_status = 'granted'
      AND COALESCE(is_enabled, false)
  );
$function$;

REVOKE ALL ON FUNCTION public.wecom_super_module_open(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.wecom_super_module_open(uuid) TO authenticated;

-- 模块内操作权限：老板（根）或企业管理员
CREATE OR REPLACE FUNCTION public._wecom_super_guard()
RETURNS uuid
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
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
  IF NOT public.wecom_super_module_open(v_root) THEN
    RAISE EXCEPTION '企微超级助手尚未开通' USING ERRCODE = '42501';
  END IF;
  IF v_uid <> v_root AND NOT public.is_enterprise_admin(v_uid) THEN
    RAISE EXCEPTION '仅企业负责人或管理员可操作企微超级助手' USING ERRCODE = '42501';
  END IF;
  RETURN v_root;
END;
$function$;

REVOKE ALL ON FUNCTION public._wecom_super_guard() FROM PUBLIC;

-- ───────────────────────── 11. 读取 RPC ─────────────────────────
-- 11.1 商户配置（不含 Token 明文）
CREATE OR REPLACE FUNCTION public.get_wecom_super_config()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
  v_cfg public.wecom_super_merchant_config%ROWTYPE;
  v_pf public.wecom_super_platform_config%ROWTYPE;
  v_device_total int;
  v_device_online int;
BEGIN
  SELECT * INTO v_cfg FROM public.wecom_super_merchant_config WHERE root_manager_id = v_root;
  SELECT * INTO v_pf FROM public.wecom_super_platform_config WHERE id = 1;
  SELECT count(*), count(*) FILTER (WHERE status = 'online')
    INTO v_device_total, v_device_online
  FROM public.wecom_super_devices WHERE root_manager_id = v_root;

  RETURN jsonb_build_object(
    'config', jsonb_build_object(
      'tokenSource', COALESCE(v_cfg.token_source, 'platform'),
      'hasOwnToken', COALESCE(btrim(COALESCE(v_cfg.own_token, '')), '') <> '',
      'seatQuota', COALESCE(v_cfg.seat_quota, v_pf.default_seat_quota, 1),
      'riskAckAt', v_cfg.risk_ack_at,
      'aiEnabled', COALESCE(v_cfg.ai_enabled, false),
      'aiMode', COALESCE(v_cfg.ai_mode, 'manual'),
      'aiDailyCap', COALESCE(v_cfg.ai_daily_cap, 10),
      'aiPerClientCap', COALESCE(v_cfg.ai_per_client_cap, 1),
      'settings', COALESCE(v_cfg.settings, '{}'::jsonb)
    ),
    'platform', jsonb_build_object(
      'tokenEnabled', COALESCE(v_pf.token_enabled, false),
      'defaultSeatQuota', COALESCE(v_pf.default_seat_quota, 1),
      'rateLimitIntervalSec', COALESCE(v_pf.rate_limit_interval_sec, 8),
      'dailySendCap', COALESCE(v_pf.daily_send_cap, 200)
    ),
    'devices', jsonb_build_object('total', v_device_total, 'online', v_device_online)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_wecom_super_config() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wecom_super_config() TO authenticated;

-- 11.2 设备列表
CREATE OR REPLACE FUNCTION public.list_wecom_super_devices()
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
      'id', d.id,
      'guid', d.guid,
      'deviceName', d.device_name,
      'areaCode', d.area_code,
      'areaName', d.area_name,
      'status', d.status,
      'loginUserid', d.login_userid,
      'loginNickname', d.login_nickname,
      'loginCorpid', d.login_corpid,
      'loginCorpName', d.login_corp_name,
      'avatarUrl', d.avatar_url,
      'lastEventAt', d.last_event_at,
      'lastError', d.last_error,
      'createdAt', d.created_at,
      'updatedAt', d.updated_at
    ) ORDER BY d.created_at DESC)
    FROM public.wecom_super_devices d
    WHERE d.root_manager_id = v_root
  ), '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_devices() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_devices() TO authenticated;

-- 11.3 好友列表
CREATE OR REPLACE FUNCTION public.list_wecom_super_contacts(
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
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
  v_offset int := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_total int;
  v_items jsonb;
BEGIN
  SELECT count(*) INTO v_total
  FROM public.wecom_super_contacts c
  WHERE c.root_manager_id = v_root
    AND (v_keyword IS NULL
         OR COALESCE(c.name, '') ILIKE '%' || v_keyword || '%'
         OR c.external_userid ILIKE '%' || v_keyword || '%'
         OR COALESCE(c.account, '') ILIKE '%' || v_keyword || '%');

  SELECT COALESCE(jsonb_agg(to_jsonb(row)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT c.id, c.external_userid AS "externalUserid", c.name, c.avatar_url AS "avatarUrl",
           c.contact_type AS "contactType", c.account, c.device_guid AS "deviceGuid",
           c.synced_at AS "syncedAt"
    FROM public.wecom_super_contacts c
    WHERE c.root_manager_id = v_root
      AND (v_keyword IS NULL
           OR COALESCE(c.name, '') ILIKE '%' || v_keyword || '%'
           OR c.external_userid ILIKE '%' || v_keyword || '%'
           OR COALESCE(c.account, '') ILIKE '%' || v_keyword || '%')
    ORDER BY c.synced_at DESC NULLS LAST, c.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_contacts(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_contacts(text, int, int) TO authenticated;

-- 11.4 群列表
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
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
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

-- 11.5 发送任务列表
CREATE OR REPLACE FUNCTION public.list_wecom_super_tasks(
  p_status text DEFAULT NULL,
  p_kind text DEFAULT NULL,
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
  v_status text := NULLIF(btrim(COALESCE(p_status, '')), '');
  v_kind text := NULLIF(btrim(COALESCE(p_kind, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
  v_offset int := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_total int;
  v_items jsonb;
BEGIN
  SELECT count(*) INTO v_total
  FROM public.wecom_super_send_tasks t
  WHERE t.root_manager_id = v_root
    AND (v_status IS NULL OR t.status = v_status)
    AND (v_kind IS NULL OR t.kind = v_kind);

  SELECT COALESCE(jsonb_agg(to_jsonb(row)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT t.id, t.kind, t.target_type AS "targetType", t.content,
           t.total_count AS "totalCount", t.sent_count AS "sentCount",
           t.fail_count AS "failCount", t.status, t.scheduled_at AS "scheduledAt",
           t.device_guid AS "deviceGuid", t.last_error AS "lastError",
           t.ai_suggestion_id AS "aiSuggestionId",
           t.created_by AS "createdBy", t.created_at AS "createdAt",
           t.updated_at AS "updatedAt"
    FROM public.wecom_super_send_tasks t
    WHERE t.root_manager_id = v_root
      AND (v_status IS NULL OR t.status = v_status)
      AND (v_kind IS NULL OR t.kind = v_kind)
    ORDER BY t.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_tasks(text, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_tasks(text, text, int, int) TO authenticated;

-- 11.6 会话列表（每个 peer_id 取最近一条）
CREATE OR REPLACE FUNCTION public.list_wecom_super_conversations(
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
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
  v_offset int := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_total int;
  v_items jsonb;
BEGIN
  WITH latest AS (
    SELECT DISTINCT ON (m.peer_id)
           m.peer_id, m.peer_type, m.direction, m.msg_type,
           m.content_text, m.room_id, m.from_id, m.sender_name,
           m.msg_time, m.created_at
    FROM public.wecom_super_messages m
    WHERE m.root_manager_id = v_root
    ORDER BY m.peer_id, m.msg_time DESC, m.created_at DESC
  )
  SELECT count(*) INTO v_total
  FROM latest l
  LEFT JOIN public.wecom_super_contacts c
    ON c.root_manager_id = v_root AND c.external_userid = l.peer_id AND l.peer_type = 'contact'
  LEFT JOIN public.wecom_super_rooms r
    ON r.root_manager_id = v_root AND r.room_id = l.peer_id AND l.peer_type = 'room'
  WHERE (v_keyword IS NULL
         OR COALESCE(c.name, '') ILIKE '%' || v_keyword || '%'
         OR COALESCE(r.name, '') ILIKE '%' || v_keyword || '%'
         OR l.peer_id ILIKE '%' || v_keyword || '%');

  WITH latest AS (
    SELECT DISTINCT ON (m.peer_id)
           m.peer_id, m.peer_type, m.direction, m.msg_type,
           m.content_text, m.room_id, m.from_id, m.sender_name,
           m.msg_time, m.created_at
    FROM public.wecom_super_messages m
    WHERE m.root_manager_id = v_root
    ORDER BY m.peer_id, m.msg_time DESC, m.created_at DESC
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(row)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT l.peer_id AS "peerId", l.peer_type AS "peerType",
           CASE WHEN l.peer_type = 'room' THEN COALESCE(r.name, l.peer_id)
                ELSE COALESCE(c.name, l.peer_id) END AS "peerName",
           CASE WHEN l.peer_type = 'room' THEN r.avatar_url ELSE c.avatar_url END AS "avatarUrl",
           l.direction, l.msg_type AS "msgType",
           l.content_text AS "lastContent", l.msg_time AS "msgTime",
           (SELECT count(*) FROM public.wecom_super_messages m2
             WHERE m2.root_manager_id = v_root AND m2.peer_id = l.peer_id) AS "messageCount"
    FROM latest l
    LEFT JOIN public.wecom_super_contacts c
      ON c.root_manager_id = v_root AND c.external_userid = l.peer_id AND l.peer_type = 'contact'
    LEFT JOIN public.wecom_super_rooms r
      ON r.root_manager_id = v_root AND r.room_id = l.peer_id AND l.peer_type = 'room'
    WHERE (v_keyword IS NULL
           OR COALESCE(c.name, '') ILIKE '%' || v_keyword || '%'
           OR COALESCE(r.name, '') ILIKE '%' || v_keyword || '%'
           OR l.peer_id ILIKE '%' || v_keyword || '%')
    ORDER BY l.msg_time DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_conversations(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_conversations(text, int, int) TO authenticated;

-- 11.7 会话内消息
CREATE OR REPLACE FUNCTION public.list_wecom_super_messages(
  p_peer_id text,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
  v_peer text := NULLIF(btrim(COALESCE(p_peer_id, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 50), 1), 200);
  v_offset int := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_total int;
  v_items jsonb;
BEGIN
  IF v_peer IS NULL THEN
    RAISE EXCEPTION '缺少会话参数' USING ERRCODE = '22023';
  END IF;

  SELECT count(*) INTO v_total
  FROM public.wecom_super_messages m
  WHERE m.root_manager_id = v_root AND m.peer_id = v_peer;

  SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row."msgTime" ASC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT m.id, m.direction, m.msg_type AS "msgType", m.peer_type AS "peerType",
           m.content_text AS "contentText",
           m.from_id AS "fromId", m.to_id AS "toId", m.room_id AS "roomId",
           m.sender_name AS "senderName", m.msg_server_id AS "msgServerId",
           m.task_id AS "taskId", m.msg_time AS "msgTime"
    FROM public.wecom_super_messages m
    WHERE m.root_manager_id = v_root AND m.peer_id = v_peer
    ORDER BY m.msg_time DESC, m.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_messages(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_messages(text, int, int) TO authenticated;

-- 11.8 AI 建议队列
CREATE OR REPLACE FUNCTION public.list_wecom_super_ai_suggestions(
  p_status text DEFAULT NULL,
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
  v_status text := NULLIF(btrim(COALESCE(p_status, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
  v_offset int := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_total int;
  v_items jsonb;
BEGIN
  SELECT count(*) INTO v_total
  FROM public.wecom_super_ai_suggestions s
  WHERE s.root_manager_id = v_root
    AND (v_status IS NULL OR s.status = v_status);

  SELECT COALESCE(jsonb_agg(to_jsonb(row)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT s.id, s.client_id AS "clientId", s.client_name AS "clientName",
           s.target_id AS "targetId", s.device_guid AS "deviceGuid",
           s.suggested_content AS "suggestedContent", s.context,
           s.status, s.task_id AS "taskId", s.last_error AS "lastError",
           s.handled_at AS "handledAt", s.created_at AS "createdAt"
    FROM public.wecom_super_ai_suggestions s
    WHERE s.root_manager_id = v_root
      AND (v_status IS NULL OR s.status = v_status)
    ORDER BY s.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_ai_suggestions(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_ai_suggestions(text, int, int) TO authenticated;

-- ───────────────────────── 12. 定时调度（pg_cron 每分钟） ─────────────────────────
create extension if not exists pg_cron;

insert into public.cron_job_config (job_name, function_url, anon_key, cron_secret)
values (
  'wecom-super-cron',
  'https://vkmfgvlfztddylbcupxl.db.superun.com/functions/v1/wecom-super-cron',
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzg2MDgzODQwLCJleHAiOjIxMDE0NDM4NDB9.JvnLyNtChX_lNu8j1KxXe2O4aart3YYKlqf-10xUotQ',
  gen_random_uuid()::text
)
on conflict (job_name) do nothing;

do $function$
begin
  perform cron.unschedule('wecom-super-cron');
exception when others then
  null;
end
$function$;

select cron.schedule(
  'wecom-super-cron',
  '* * * * *',
  $function$
  select net.http_post(
    url := (select function_url from public.cron_job_config where job_name = 'wecom-super-cron'),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', (select anon_key from public.cron_job_config where job_name = 'wecom-super-cron'),
      'Authorization', 'Bearer ' || (select anon_key from public.cron_job_config where job_name = 'wecom-super-cron'),
      'x-cron-secret', (select cron_secret from public.cron_job_config where job_name = 'wecom-super-cron')
    ),
    body := '{"action":"scheduled_scan"}'
  );
  $function$
);
