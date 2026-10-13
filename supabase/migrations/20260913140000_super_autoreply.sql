-- 企微超级助手：外挂自动回复 + 设备绑定员工
-- 1) devices 增绑定员工；2) 商户配置增自动回复字段；3) 待处理队列；
-- 4) 发送任务 kind 增 auto_reply；5) 建议日志增来源；
-- 6) 重建/新增 RPC（配置读、设备列表、任务列表、企业成员列表、绑定、绑定下拉）。
-- 迁移经 sxq db query --file 生效（migrations 目录不随 push 上传）。

-- ───────────────────────── 1. 设备绑定员工 ─────────────────────────
ALTER TABLE public.wecom_super_devices
  ADD COLUMN IF NOT EXISTS bound_manager_id uuid REFERENCES public.managers(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_wecom_super_devices_bound
  ON public.wecom_super_devices (root_manager_id, bound_manager_id)
  WHERE bound_manager_id IS NOT NULL;

-- ───────────────────────── 2. 商户自动回复配置 ─────────────────────────
ALTER TABLE public.wecom_super_merchant_config
  ADD COLUMN IF NOT EXISTS autoreply_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS autoreply_scene text NOT NULL DEFAULT 'private',
  ADD COLUMN IF NOT EXISTS autoreply_start time NOT NULL DEFAULT '09:00',
  ADD COLUMN IF NOT EXISTS autoreply_end time NOT NULL DEFAULT '21:30',
  ADD COLUMN IF NOT EXISTS autoreply_min_score int NOT NULL DEFAULT 70,
  ADD COLUMN IF NOT EXISTS autoreply_cooldown_min int NOT NULL DEFAULT 10,
  ADD COLUMN IF NOT EXISTS autoreply_daily_cap int NOT NULL DEFAULT 50,
  ADD COLUMN IF NOT EXISTS autoreply_device_guids jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS autoreply_owner_userid text,
  ADD COLUMN IF NOT EXISTS autoreply_owner_name text,
  ADD COLUMN IF NOT EXISTS autoreply_group_atonly boolean NOT NULL DEFAULT true;

DO $$
BEGIN
  ALTER TABLE public.wecom_super_merchant_config
    ADD CONSTRAINT wecom_super_autoreply_scene_chk
    CHECK (autoreply_scene IN ('private', 'private_group'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ───────────────────────── 3. 自动回复待处理队列 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.wecom_super_autoreply_queue (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  device_guid text NOT NULL,
  peer_id text NOT NULL,                                   -- 好友 userId 或群 roomId
  peer_type text NOT NULL DEFAULT 'contact',               -- contact | room
  peer_name text,
  last_msgid text,
  last_msg_text text,
  last_from_id text,
  unread_count int NOT NULL DEFAULT 0,
  -- pending 待处理 | handling 抢占中 | replied 已自动回 | escalated 已转人工
  -- ignored 规则跳过（未@/通知抑制） | closed 关闭（非工作时段/人工已回/过期）
  status text NOT NULL DEFAULT 'pending',
  decision_reason text,
  suggestion_log_id uuid,
  task_id uuid,
  last_in_at timestamptz NOT NULL DEFAULT now(),
  handled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_super_arq_peer UNIQUE (device_guid, peer_id),
  CONSTRAINT wecom_super_arq_peer_type_chk CHECK (peer_type IN ('contact', 'room')),
  CONSTRAINT wecom_super_arq_status_chk CHECK (status IN
    ('pending', 'handling', 'replied', 'escalated', 'ignored', 'closed'))
);

CREATE INDEX IF NOT EXISTS idx_wecom_super_arq_scan
  ON public.wecom_super_autoreply_queue (root_manager_id, status, last_in_at DESC);

ALTER TABLE public.wecom_super_autoreply_queue ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.wecom_super_autoreply_queue FROM PUBLIC;
REVOKE ALL ON public.wecom_super_autoreply_queue FROM anon, authenticated;
GRANT ALL ON public.wecom_super_autoreply_queue TO service_role;

-- ───────────────────────── 4. 发送任务 kind 增 auto_reply ─────────────────────────
ALTER TABLE public.wecom_super_send_tasks
  DROP CONSTRAINT IF EXISTS wecom_super_task_kind_chk;
ALTER TABLE public.wecom_super_send_tasks
  ADD CONSTRAINT wecom_super_task_kind_chk CHECK (kind IN
    ('single', 'private_mass', 'group_mass', 'ai_manual', 'ai_auto', 'auto_reply'));

-- ───────────────────────── 5. 建议日志增来源标记 ─────────────────────────
ALTER TABLE public.wecom_reply_suggestion_logs
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'archive';

DO $$
BEGIN
  ALTER TABLE public.wecom_reply_suggestion_logs
    ADD CONSTRAINT wecom_reply_suggestion_source_chk
    CHECK (source IN ('archive', 'super'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ───────────────────────── 6. 配置读取 RPC：带自动回复配置 ─────────────────────────
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
      'settings', COALESCE(v_cfg.settings, '{}'::jsonb),
      'autoreplyEnabled', COALESCE(v_cfg.autoreply_enabled, false),
      'autoreplyScene', COALESCE(v_cfg.autoreply_scene, 'private'),
      'autoreplyStart', to_char(COALESCE(v_cfg.autoreply_start, '09:00'::time), 'HH24:MI'),
      'autoreplyEnd', to_char(COALESCE(v_cfg.autoreply_end, '21:30'::time), 'HH24:MI'),
      'autoreplyMinScore', COALESCE(v_cfg.autoreply_min_score, 70),
      'autoreplyCooldownMin', COALESCE(v_cfg.autoreply_cooldown_min, 10),
      'autoreplyDailyCap', COALESCE(v_cfg.autoreply_daily_cap, 50),
      'autoreplyDeviceGuids', COALESCE(v_cfg.autoreply_device_guids, '[]'::jsonb),
      'autoreplyOwnerUserid', v_cfg.autoreply_owner_userid,
      'autoreplyOwnerName', v_cfg.autoreply_owner_name,
      'autoreplyGroupAtonly', COALESCE(v_cfg.autoreply_group_atonly, true)
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

-- ───────────────────────── 7. 设备列表 RPC：带绑定员工 ─────────────────────────
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
      'boundManagerId', d.bound_manager_id,
      'boundManagerName', mp.nickname,
      'lastEventAt', d.last_event_at,
      'lastError', d.last_error,
      'createdAt', d.created_at,
      'updatedAt', d.updated_at
    ) ORDER BY d.created_at DESC)
    FROM public.wecom_super_devices d
    LEFT JOIN public.profiles mp ON mp.id = d.bound_manager_id
    WHERE d.root_manager_id = v_root
  ), '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_devices() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_devices() TO authenticated;

-- ───────────────────────── 8. 任务列表 RPC：返回 result（区分自动回复/转人工） ─────────────────────────
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
           t.ai_suggestion_id AS "aiSuggestionId", t.result AS "result",
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

-- ───────────────────────── 9. 企业成员列表：外挂设备三字段 ─────────────────────────
CREATE OR REPLACE FUNCTION public.list_enterprise_sub_accounts(
  p_enterprise_id uuid DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_ent uuid;
  v_owner uuid;
  v_result json;
BEGIN
  IF v_uid IS NULL THEN
    RETURN '[]'::json;
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_members', v_uid) THEN
    RETURN '[]'::json;
  END IF;

  v_ent := COALESCE(
    p_enterprise_id,
    (SELECT ee.enterprise_id
       FROM public.enterprise_employments ee
      WHERE ee.auth_user_id = v_uid
        AND ee.status IN ('active', 'disabled', 'pending')
      ORDER BY ee.is_primary DESC, ee.created_at DESC
      LIMIT 1),
    (SELECT e.id FROM public.enterprises e WHERE e.owner_profile_id = v_uid LIMIT 1),
    (SELECT p.enterprise_id FROM public.profiles p WHERE p.id = v_uid)
  );
  IF v_ent IS NULL THEN
    RETURN '[]'::json;
  END IF;
  IF NOT public.is_enterprise_member(v_ent, v_uid) THEN
    RETURN '[]'::json;
  END IF;

  SELECT e.owner_profile_id INTO v_owner FROM public.enterprises e WHERE e.id = v_ent;

  SELECT COALESCE(json_agg(x ORDER BY x.sort_status, x.created_at DESC), '[]'::json)
  INTO v_result
  FROM (
    SELECT
      ee.id AS employment_id,
      ee.auth_user_id AS id,
      p.nickname,
      p.phone,
      p.avatar_url,
      ee.sub_role,
      ee.enterprise_role_id,
      COALESCE(r.name, CASE WHEN ee.sub_role = 'admin' THEN '管理员' ELSE '健康管理师' END) AS role_name,
      ee.permissions,
      ee.status,
      ee.is_primary,
      COALESCE(p.is_disabled, false) AS is_disabled,
      ee.created_at,
      (SELECT count(*)::int FROM public.client_relations cr WHERE cr.manager_id = ee.auth_user_id) AS client_count,
      (SELECT count(*)::int FROM public.surveys s WHERE s.manager_id = ee.auth_user_id) AS survey_count,
      EXISTS (SELECT 1 FROM public.managers m WHERE m.id = ee.auth_user_id) AS has_manager_card,
      COALESCE(p.wecom_userid, '') AS wecom_userid,
      COALESCE((SELECT m.is_system_default FROM public.managers m WHERE m.id = ee.auth_user_id), false) AS is_system_default,
      sup.super_device_guid AS super_device_guid,
      sup.super_device_name AS super_device_name,
      COALESCE(sup.super_online, false) AS super_online,
      CASE ee.status WHEN 'active' THEN 0 WHEN 'pending' THEN 1 WHEN 'disabled' THEN 2 ELSE 3 END AS sort_status
    FROM public.enterprise_employments ee
    JOIN public.profiles p ON p.id = ee.auth_user_id
    LEFT JOIN public.enterprise_roles r ON r.id = ee.enterprise_role_id
    LEFT JOIN LATERAL (
      SELECT d.guid AS super_device_guid,
             d.login_nickname AS super_device_name,
             (d.status = 'online') AS super_online
      FROM public.wecom_super_devices d
      WHERE d.bound_manager_id = ee.auth_user_id
      ORDER BY d.updated_at DESC
      LIMIT 1
    ) sup ON true
    WHERE ee.enterprise_id = v_ent
      AND (v_owner IS NULL OR ee.auth_user_id <> v_owner)
  ) x;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_sub_accounts(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_enterprise_sub_accounts(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_enterprise_sub_accounts(uuid) TO authenticated;

-- ───────────────────────── 10. 绑定/解绑/换绑设备 ─────────────────────────
CREATE OR REPLACE FUNCTION public.bind_wecom_super_device(
  p_guid text,
  p_manager_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
  v_manager_name text;
BEGIN
  IF NULLIF(btrim(COALESCE(p_guid, '')), '') IS NULL THEN
    RAISE EXCEPTION '缺少设备标识' USING ERRCODE = '23514';
  END IF;

  -- 设备必须属于本商户
  IF NOT EXISTS (
    SELECT 1 FROM public.wecom_super_devices
    WHERE root_manager_id = v_root AND guid = btrim(p_guid)
  ) THEN
    RAISE EXCEPTION '设备不存在' USING ERRCODE = '42501';
  END IF;

  IF p_manager_id IS NULL THEN
    -- 解绑
    UPDATE public.wecom_super_devices
       SET bound_manager_id = NULL, updated_at = now()
     WHERE root_manager_id = v_root AND guid = btrim(p_guid);
  ELSE
    -- 员工必须属于本商户且存在 managers 名片
    SELECT p.nickname INTO v_manager_name
      FROM public.profiles p
     WHERE p.id = p_manager_id
       AND COALESCE(p.parent_manager_id, p.id) = v_root
       AND EXISTS (SELECT 1 FROM public.managers m WHERE m.id = p.id);
    IF v_manager_name IS NULL THEN
      RAISE EXCEPTION '员工不存在或不属于本企业' USING ERRCODE = '42501';
    END IF;

    -- 一名员工同一时间只绑一台：先解绑其名下其他设备（换绑）
    UPDATE public.wecom_super_devices
       SET bound_manager_id = NULL, updated_at = now()
     WHERE root_manager_id = v_root
       AND bound_manager_id = p_manager_id
       AND guid <> btrim(p_guid);

    UPDATE public.wecom_super_devices
       SET bound_manager_id = p_manager_id, updated_at = now()
     WHERE root_manager_id = v_root AND guid = btrim(p_guid);
  END IF;

  RETURN jsonb_build_object('guid', btrim(p_guid), 'boundManagerId', p_manager_id, 'ok', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.bind_wecom_super_device(text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.bind_wecom_super_device(text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.bind_wecom_super_device(text, uuid) TO authenticated;

-- ───────────────────────── 11. 可绑定员工下拉（带当前绑定设备） ─────────────────────────
CREATE OR REPLACE FUNCTION public.list_enterprise_managers_for_bind()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
  v_ent uuid;
BEGIN
  SELECT enterprise_id INTO v_ent
  FROM public.enterprise_employments
  WHERE auth_user_id = v_root AND is_primary = true
  LIMIT 1;
  IF v_ent IS NULL THEN
    SELECT enterprise_id INTO v_ent FROM public.profiles WHERE id = v_root;
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(to_jsonb(row) ORDER BY row.status_sort, row.nickname)
    FROM (
      SELECT ee.auth_user_id AS "managerId",
             p.nickname,
             p.phone,
             p.avatar_url AS "avatarUrl",
             COALESCE(r.name, CASE WHEN ee.sub_role = 'admin' THEN '管理员' ELSE '健康管理师' END) AS "roleName",
             ee.status,
             CASE WHEN ee.status = 'active' THEN 0 WHEN ee.status = 'pending' THEN 1 ELSE 2 END AS status_sort,
             bd.guid AS "boundDeviceGuid",
             bd.login_nickname AS "boundDeviceName",
             bd.status AS "boundDeviceStatus"
      FROM public.enterprise_employments ee
      JOIN public.profiles p ON p.id = ee.auth_user_id
      LEFT JOIN public.enterprise_roles r ON r.id = ee.enterprise_role_id
      LEFT JOIN LATERAL (
        SELECT d.guid, d.login_nickname, d.status
        FROM public.wecom_super_devices d
        WHERE d.root_manager_id = v_root AND d.bound_manager_id = ee.auth_user_id
        ORDER BY d.updated_at DESC LIMIT 1
      ) bd ON true
      WHERE ee.enterprise_id = v_ent
        AND ee.status IN ('active', 'pending', 'disabled')
        AND EXISTS (SELECT 1 FROM public.managers m WHERE m.id = ee.auth_user_id)
    ) row
  ), '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_enterprise_managers_for_bind() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_enterprise_managers_for_bind() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_enterprise_managers_for_bind() TO authenticated;

NOTIFY pgrst, 'reload schema';
