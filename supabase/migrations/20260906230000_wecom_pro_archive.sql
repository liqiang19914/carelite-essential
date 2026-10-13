-- ============================================================================
-- 企微助手 Pro —— Task 7/10/11：会话存档（配置 / 会话 / 消息 / 敏感词审计）
--
-- 变更概览：
--   1) merchant_wecom_settings 加列：存档 secret / 私钥环 / 启用开关 / 采集水位与心跳
--   2) merchant_wecom_archive_rooms     存档会话表（单聊 / 群聊）
--   3) merchant_wecom_archive_messages  存档消息表（含敏感词命中标记）
--   4) merchant_wecom_sensitive_words   敏感词库（平台默认 root=NULL + 商户自定义）
--   5) system_settings 写入采集服务入口密钥 wecom_archive_ingest_secret
--   6) RPC：存档配置读写 / 敏感词库管理 / 会话列表 / 消息流 / 审计列表
--
-- 约定：表均 REVOKE 全部直连权限，只走 SECURITY DEFINER RPC（SET search_path=''）；
--       Pro 读取统一 wecom_pro_module_open(root) 双闸门 + 权限码收口；
--       存档 secret / 私钥任何 RPC 都不回传明文，只回 has / 尾号。
--       采集服务（VPS Node）经 wecom-archive-ingest EF（x-ingest-secret 认证）写入。
-- ============================================================================

-- ───────────────────────── 1. 存档配置列 ─────────────────────────
ALTER TABLE public.merchant_wecom_settings
  ADD COLUMN IF NOT EXISTS archive_secret text,
  ADD COLUMN IF NOT EXISTS archive_private_keys jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS archive_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS archive_last_seq bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS archive_checked_at timestamptz,
  ADD COLUMN IF NOT EXISTS archive_collector_heartbeat timestamptz,
  ADD COLUMN IF NOT EXISTS archive_collector_ip text;

COMMENT ON COLUMN public.merchant_wecom_settings.archive_secret IS '会话内容存档 Secret（企微管理后台获取，仅采集服务经 ingest EF 使用，RPC 不回传明文）';
COMMENT ON COLUMN public.merchant_wecom_settings.archive_private_keys IS 'RSA 私钥环：[{publickey_ver:int, private_key_pem:text}]，与企微后台公钥版本对应';
COMMENT ON COLUMN public.merchant_wecom_settings.archive_enabled IS '商户是否已开通并启用会话存档采集';
COMMENT ON COLUMN public.merchant_wecom_settings.archive_last_seq IS '会话存档采集水位 seq（采集服务上报）';
COMMENT ON COLUMN public.merchant_wecom_settings.archive_collector_heartbeat IS '采集服务最近心跳时间';
COMMENT ON COLUMN public.merchant_wecom_settings.archive_collector_ip IS '采集服务最近上报的出口公网 IP（用于企微后台可信 IP 配置指引）';

-- ───────────────────────── 2. 存档会话表 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.merchant_wecom_archive_rooms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  -- 群聊为企微 roomid；单聊由采集服务构造为 'single:<external_userid>'
  roomid text NOT NULL,
  room_type text NOT NULL CHECK (room_type IN ('single', 'group')),
  room_name text,
  owner_userid text,
  -- 会话涉及的企微员工 userid（单聊 1 个，群聊随消息累积）
  staff_userids text[] NOT NULL DEFAULT '{}',
  -- 单聊对方客户
  external_userid text,
  member_count int NOT NULL DEFAULT 0,
  last_msg_at timestamptz,
  last_msg_summary text,
  sensitive_count int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_archive_room UNIQUE (root_manager_id, roomid)
);

CREATE INDEX IF NOT EXISTS idx_wecom_archive_rooms_root
  ON public.merchant_wecom_archive_rooms (root_manager_id, last_msg_at DESC);

-- ───────────────────────── 3. 存档消息表 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.merchant_wecom_archive_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  msgid text NOT NULL,
  seq bigint,
  action text NOT NULL DEFAULT 'send' CHECK (action IN ('send', 'recall')),
  roomid text NOT NULL,
  room_type text NOT NULL DEFAULT 'single' CHECK (room_type IN ('single', 'group')),
  from_userid text,
  from_name text,
  tolist text[] NOT NULL DEFAULT '{}',
  msg_type text NOT NULL,
  -- 解密后的消息体（text / link / weapp / image / voice / video / file 等原始结构）
  content jsonb NOT NULL DEFAULT '{}'::jsonb,
  media_oss_key text,
  media_url text,
  -- 企微消息时间戳（毫秒）
  msgtime bigint,
  sensitive_hit boolean NOT NULL DEFAULT false,
  sensitive_words text[] NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_archive_msg UNIQUE (root_manager_id, msgid)
);

CREATE INDEX IF NOT EXISTS idx_wecom_archive_msgs_room
  ON public.merchant_wecom_archive_messages (root_manager_id, roomid, msgtime);
CREATE INDEX IF NOT EXISTS idx_wecom_archive_msgs_audit
  ON public.merchant_wecom_archive_messages (root_manager_id, sensitive_hit, msgtime DESC);
CREATE INDEX IF NOT EXISTS idx_wecom_archive_msgs_seq
  ON public.merchant_wecom_archive_messages (root_manager_id, seq);

ALTER TABLE public.merchant_wecom_archive_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.merchant_wecom_archive_messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.merchant_wecom_archive_rooms FROM anon, authenticated;
REVOKE ALL ON public.merchant_wecom_archive_messages FROM anon, authenticated;

-- ───────────────────────── 4. 敏感词库 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.merchant_wecom_sensitive_words (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- NULL = 平台默认词（全商户共享）；非 NULL = 商户自定义
  root_manager_id uuid REFERENCES public.managers(id) ON DELETE CASCADE,
  scope text NOT NULL DEFAULT 'merchant' CHECK (scope IN ('platform', 'merchant')),
  word text NOT NULL,
  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT mw_sensitive_word_check CHECK (char_length(btrim(word)) BETWEEN 1 AND 32)
);

-- 平台词与商户词分别去重（NULL 不参与普通唯一约束，用部分唯一索引）
CREATE UNIQUE INDEX IF NOT EXISTS uq_sensitive_words_merchant
  ON public.merchant_wecom_sensitive_words (root_manager_id, word)
  WHERE root_manager_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_sensitive_words_platform
  ON public.merchant_wecom_sensitive_words (word)
  WHERE root_manager_id IS NULL;

ALTER TABLE public.merchant_wecom_sensitive_words ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.merchant_wecom_sensitive_words FROM anon, authenticated;

-- 平台默认敏感词种子（营销合规/飞单风险高频词，商户可增不可删平台词）
INSERT INTO public.merchant_wecom_sensitive_words (root_manager_id, scope, word)
SELECT NULL, 'platform', w.word
FROM (VALUES
  ('加微信'), ('私下转账'), ('返利'), ('刷单'), ('返现'),
  ('回扣'), ('私收款'), ('二维码付款'), ('支付宝转'), ('红包返利'),
  ('私下交易'), ('绕开平台'), ('保证治愈'), ('百分百见效')
) AS w(word)
WHERE NOT EXISTS (SELECT 1 FROM public.merchant_wecom_sensitive_words WHERE root_manager_id IS NULL AND word = w.word);

-- ───────────────────────── 5. 采集服务入口密钥（平台级） ─────────────────────────
INSERT INTO public.system_settings (key, value)
SELECT 'wecom_archive_ingest_secret', encode(gen_random_bytes(24), 'hex')
WHERE NOT EXISTS (
  SELECT 1 FROM public.system_settings WHERE key = 'wecom_archive_ingest_secret'
);

-- ───────────────────────── 6. RPC ─────────────────────────

-- 6.1 存档配置读取（只回 has/尾号，不回传明文密钥）
CREATE OR REPLACE FUNCTION public.get_wecom_pro_archive_config()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_s public.merchant_wecom_settings%ROWTYPE;
  v_room_count int;
  v_msg_count bigint;
  v_today_msg int;
  v_sensitive_count int;
  v_tz text;
  v_day_start timestamptz;
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

  SELECT * INTO v_s FROM public.merchant_wecom_settings WHERE root_manager_id = v_root;

  SELECT count(*)::int, count(*)::bigint,
         count(*) FILTER (WHERE m.created_at >= date_trunc('day', now())),
         count(*) FILTER (WHERE m.sensitive_hit)::int
  INTO v_room_count, v_msg_count, v_today_msg, v_sensitive_count
  FROM public.merchant_wecom_archive_messages m
  WHERE m.root_manager_id = v_root;

  RETURN jsonb_build_object(
    'enabled', COALESCE(v_s.archive_enabled, false),
    'hasSecret', COALESCE(v_s.archive_secret, '') <> '',
    'secretTail', CASE WHEN COALESCE(v_s.archive_secret, '') <> ''
                       THEN right(v_s.archive_secret, 4) ELSE NULL END,
    'privateKeys', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('publickeyVer', k->>'publickey_ver', 'hasKey', true)
                       ORDER BY k->>'publickey_ver')
      FROM jsonb_array_elements(COALESCE(v_s.archive_private_keys, '[]'::jsonb)) k
    ), '[]'::jsonb),
    'checkedAt', v_s.archive_checked_at,
    'lastSeq', COALESCE(v_s.archive_last_seq, 0),
    'collectorHeartbeat', v_s.archive_collector_heartbeat,
    'collectorIp', v_s.archive_collector_ip,
    'roomCount', COALESCE(v_room_count, 0),
    'messageCount', COALESCE(v_msg_count, 0),
    'todayMessageCount', COALESCE(v_today_msg, 0),
    'sensitiveCount', COALESCE(v_sensitive_count, 0)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_wecom_pro_archive_config() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wecom_pro_archive_config() TO authenticated;

-- 6.2 存档配置保存（NULL = 不变；私钥环非 NULL 全量替换；仅老板/管理员）
CREATE OR REPLACE FUNCTION public.save_wecom_pro_archive_config(
  p_secret text DEFAULT NULL,
  p_private_keys jsonb DEFAULT NULL,
  p_enabled boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_secret text;
  v_keys jsonb;
  v_enabled boolean;
  k jsonb;
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
    RAISE EXCEPTION '没有会话存档配置权限' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.merchant_wecom_settings (root_manager_id)
  VALUES (v_root)
  ON CONFLICT (root_manager_id) DO NOTHING;

  IF p_secret IS NOT NULL THEN
    v_secret := btrim(p_secret);
    IF v_secret <> '' AND char_length(v_secret) > 200 THEN
      RAISE EXCEPTION '存档 Secret 长度不合法' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF p_private_keys IS NOT NULL THEN
    IF jsonb_typeof(p_private_keys) <> 'array' THEN
      RAISE EXCEPTION '私钥配置格式不正确' USING ERRCODE = '22023';
    END IF;
    FOR k IN SELECT * FROM jsonb_array_elements(p_private_keys)
    LOOP
      IF COALESCE(btrim(k->>'private_key_pem'), '') = ''
         OR k->>'publickey_ver' IS NULL THEN
        RAISE EXCEPTION '私钥配置缺少公钥版本或私钥内容' USING ERRCODE = '22023';
      END IF;
    END LOOP;
    v_keys := p_private_keys;
  END IF;

  v_enabled := p_enabled;

  UPDATE public.merchant_wecom_settings
  SET archive_secret = CASE WHEN v_secret IS NOT NULL THEN NULLIF(v_secret, '') ELSE archive_secret END,
      archive_private_keys = COALESCE(v_keys, archive_private_keys),
      archive_enabled = COALESCE(v_enabled, archive_enabled),
      archive_checked_at = now(),
      updated_at = now()
  WHERE root_manager_id = v_root;

  RETURN jsonb_build_object('ok', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.save_wecom_pro_archive_config(text, jsonb, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_wecom_pro_archive_config(text, jsonb, boolean) TO authenticated;

-- 6.3 敏感词库（平台词 + 本商户词）
CREATE OR REPLACE FUNCTION public.list_wecom_pro_sensitive_words()
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
  IF NOT public.has_enterprise_permission('wecom_pro_audit', v_uid) THEN
    RAISE EXCEPTION '没有敏感审计权限' USING ERRCODE = '42501';
  END IF;

  RETURN jsonb_build_object(
    'platform', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', id, 'word', word) ORDER BY word)
      FROM public.merchant_wecom_sensitive_words WHERE root_manager_id IS NULL
    ), '[]'::jsonb),
    'merchant', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', id, 'word', word, 'createdAt', created_at)
                       ORDER BY created_at DESC)
      FROM public.merchant_wecom_sensitive_words
      WHERE root_manager_id = v_root
    ), '[]'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_pro_sensitive_words() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_pro_sensitive_words() TO authenticated;

-- 6.4 新增商户敏感词
CREATE OR REPLACE FUNCTION public.save_wecom_pro_sensitive_word(p_word text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_word text := btrim(COALESCE(p_word, ''));
  v_id uuid;
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
  IF NOT public.has_enterprise_permission('wecom_pro_audit', v_uid) THEN
    RAISE EXCEPTION '没有敏感审计权限' USING ERRCODE = '42501';
  END IF;
  IF char_length(v_word) NOT BETWEEN 1 AND 32 THEN
    RAISE EXCEPTION '敏感词长度需在 1-32 字之间' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.merchant_wecom_sensitive_words (root_manager_id, scope, word, created_by)
  VALUES (v_root, 'merchant', v_word, v_uid)
  ON CONFLICT (root_manager_id, word) WHERE root_manager_id IS NOT NULL
  DO UPDATE SET word = EXCLUDED.word
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'word', v_word);
END;
$function$;

REVOKE ALL ON FUNCTION public.save_wecom_pro_sensitive_word(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_wecom_pro_sensitive_word(text) TO authenticated;

-- 6.5 删除商户敏感词（平台词不可删）
CREATE OR REPLACE FUNCTION public.delete_wecom_pro_sensitive_word(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
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
  IF NOT public.has_enterprise_permission('wecom_pro_audit', v_uid) THEN
    RAISE EXCEPTION '没有敏感审计权限' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.merchant_wecom_sensitive_words
  WHERE id = p_id AND root_manager_id = v_root AND scope = 'merchant';

  RETURN jsonb_build_object('ok', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_wecom_pro_sensitive_word(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_wecom_pro_sensitive_word(uuid) TO authenticated;

-- 6.6 存档会话列表（员工仅可见自己参与的会话）
CREATE OR REPLACE FUNCTION public.list_wecom_pro_archive_rooms(
  p_room_type text DEFAULT NULL,
  p_keyword text DEFAULT NULL,
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
  WHERE r.root_manager_id = v_root
    AND (v_type = '' OR r.room_type = v_type)
    AND (
      v_kw = ''
      OR r.room_name ILIKE '%' || v_kw || '%'
      OR r.external_userid ILIKE '%' || v_kw || '%'
    )
    AND (
      v_is_admin
      OR (v_my_userid <> '' AND v_my_userid = ANY (r.staff_userids))
    );

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.last_msg_at DESC NULLS LAST), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT r.roomid, r.room_type, r.room_name, r.external_userid,
           r.owner_userid, r.staff_userids, r.member_count,
           r.last_msg_at, r.last_msg_summary, r.sensitive_count
    FROM public.merchant_wecom_archive_rooms r
    WHERE r.root_manager_id = v_root
      AND (v_type = '' OR r.room_type = v_type)
      AND (
        v_kw = ''
        OR r.room_name ILIKE '%' || v_kw || '%'
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

-- 6.7 会话消息流（分页倒序取、返回时转正序；员工仅自己参与的会话）
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

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.msgtime ASC NULLS LAST, t.created_at ASC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT m.msgid, m.seq, m.action, m.room_type, m.from_userid, m.from_name,
           m.tolist, m.msg_type, m.content, m.media_url, m.msgtime,
           m.sensitive_hit, m.sensitive_words,
           to_timestamp(m.msgtime / 1000.0) AT TIME ZONE 'UTC' AS msg_at
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

-- 6.8 敏感词审计列表（命中记录；员工仅自己会话）
CREATE OR REPLACE FUNCTION public.list_wecom_pro_audit(
  p_word text DEFAULT NULL,
  p_room_type text DEFAULT NULL,
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
  v_word text := btrim(COALESCE(p_word, ''));
  v_type text := btrim(COALESCE(p_room_type, ''));
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
  IF NOT public.has_enterprise_permission('wecom_pro_audit', v_uid) THEN
    RAISE EXCEPTION '没有敏感审计权限' USING ERRCODE = '42501';
  END IF;

  v_is_admin := public.is_enterprise_admin(v_uid);
  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
    v_my_userid := btrim(COALESCE(v_my_userid, ''));
  END IF;

  SELECT count(*)::int INTO v_total
  FROM public.merchant_wecom_archive_messages m
  WHERE m.root_manager_id = v_root
    AND m.sensitive_hit = true
    AND (v_word = '' OR m.sensitive_words @> ARRAY[v_word])
    AND (v_type = '' OR m.room_type = v_type)
    AND (
      v_is_admin
      OR EXISTS (
        SELECT 1 FROM public.merchant_wecom_archive_rooms r
        WHERE r.root_manager_id = v_root AND r.roomid = m.roomid
          AND v_my_userid <> '' AND v_my_userid = ANY (r.staff_userids)
      )
    );

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.msgtime DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT m.msgid, m.roomid, m.room_type, m.from_userid, m.from_name,
           m.msg_type,
           LEFT(COALESCE(m.content->>'content', m.content->>'title', ''), 200) AS text_preview,
           m.sensitive_words,
           to_timestamp(m.msgtime / 1000.0) AT TIME ZONE 'UTC' AS msg_at,
           r.room_name,
           r.external_userid
    FROM public.merchant_wecom_archive_messages m
    LEFT JOIN public.merchant_wecom_archive_rooms r
      ON r.root_manager_id = m.root_manager_id AND r.roomid = m.roomid
    WHERE m.root_manager_id = v_root
      AND m.sensitive_hit = true
      AND (v_word = '' OR m.sensitive_words @> ARRAY[v_word])
      AND (v_type = '' OR m.room_type = v_type)
      AND (
        v_is_admin
        OR (v_my_userid <> '' AND v_my_userid = ANY (r.staff_userids))
      )
    ORDER BY m.msgtime DESC
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

REVOKE ALL ON FUNCTION public.list_wecom_pro_audit(text, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_pro_audit(text, text, int, int) TO authenticated;
