-- 企微助手 SCRM 模块：好友（客户联系 + 客服会话）、员工活码、客户联系 Secret
-- 读取类 RPC 走企业根 scope（员工持权限码可看）；配置保存类仅企业负责人。

-- ───────────────────────── 1. merchant_wecom_settings 加列 ─────────────────────────
ALTER TABLE public.merchant_wecom_settings
  ADD COLUMN IF NOT EXISTS contact_secret text,
  ADD COLUMN IF NOT EXISTS contact_access_token text,
  ADD COLUMN IF NOT EXISTS contact_token_expires_at timestamptz;

COMMENT ON COLUMN public.merchant_wecom_settings.contact_secret IS
  '企业微信客户联系 Secret，仅服务端换取客户联系 access_token；禁止返回前端明文。';

-- ───────────────────────── 2. 好友表 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.merchant_wecom_contacts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  external_userid text NOT NULL,
  type text NOT NULL DEFAULT 'contact' CHECK (type IN ('kf','contact')),
  name text,
  avatar_url text,
  unionid text,
  follow_userids text[] NOT NULL DEFAULT '{}',
  profile_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  source_state text,
  last_message_at timestamptz,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_contact UNIQUE (root_manager_id, external_userid)
);

CREATE INDEX IF NOT EXISTS idx_wecom_contacts_root_recent
  ON public.merchant_wecom_contacts (root_manager_id, last_message_at DESC);
CREATE INDEX IF NOT EXISTS idx_wecom_contacts_profile
  ON public.merchant_wecom_contacts (root_manager_id, profile_id) WHERE profile_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_wecom_contacts_unionid
  ON public.merchant_wecom_contacts (root_manager_id, unionid) WHERE unionid IS NOT NULL;

ALTER TABLE public.merchant_wecom_contacts ENABLE ROW LEVEL SECURITY;

-- ───────────────────────── 3. 员工活码表 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.merchant_wecom_contact_ways (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  config_id text NOT NULL,
  qr_code text,
  remark text,
  state text,
  userids text[] NOT NULL DEFAULT '{}',
  type int NOT NULL DEFAULT 2,
  scene int NOT NULL DEFAULT 1,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','deleted')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_contact_way UNIQUE (root_manager_id, config_id)
);

CREATE INDEX IF NOT EXISTS idx_wecom_contact_ways_root
  ON public.merchant_wecom_contact_ways (root_manager_id, created_at DESC);

ALTER TABLE public.merchant_wecom_contact_ways ENABLE ROW LEVEL SECURITY;

-- ───────────────────────── 4. 配置读取：追加客户联系 Secret 摘要 ─────────────────────────
CREATE OR REPLACE FUNCTION public.get_merchant_wecom_config()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_settings jsonb;
  v_groups jsonb;
  v_tips jsonb;
  v_tip_count int;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_merchant_root(auth.uid()) THEN
    RETURN NULL::jsonb;
  END IF;
  v_root := auth.uid();

  SELECT to_jsonb(s) INTO v_settings
  FROM (
    SELECT
      id, root_manager_id, scheduled_enabled, scheduled_time, timezone,
      agent_manager_id, welcome_message,
      single_chat_corp_id, single_chat_agent_id, single_chat_enabled,
      (single_chat_secret IS NOT NULL AND single_chat_secret <> '') AS has_single_chat_secret,
      right(single_chat_secret, 4) AS single_chat_secret_tail,
      (single_chat_token IS NOT NULL AND single_chat_token <> '') AS has_single_chat_token,
      right(single_chat_token, 4) AS single_chat_token_tail,
      (single_chat_aes_key IS NOT NULL AND single_chat_aes_key <> '') AS has_single_chat_aes_key,
      right(single_chat_aes_key, 4) AS single_chat_aes_tail,
      (contact_secret IS NOT NULL AND contact_secret <> '') AS has_contact_secret,
      right(contact_secret, 4) AS contact_secret_tail,
      callback_domain,
      single_chat_callback_verified_at, single_chat_last_callback_at,
      kf_open_kfid,
      (kf_token IS NOT NULL AND kf_token <> '') AS has_kf_token,
      right(kf_token, 4) AS kf_token_tail,
      (kf_aes_key IS NOT NULL AND kf_aes_key <> '') AS has_kf_aes_key,
      right(kf_aes_key, 4) AS kf_aes_tail,
      kf_mode, kf_ai_agent_manager_id, kf_verified_at, kf_last_callback_at,
      tip_cursor, last_scheduled_date, created_at, updated_at
    FROM public.merchant_wecom_settings
    WHERE root_manager_id = v_root
  ) s;

  SELECT COALESCE(jsonb_agg(to_jsonb(g) ORDER BY g.created_at), '[]'::jsonb) INTO v_groups
  FROM (
    SELECT
      id, name,
      CASE WHEN webhook_url LIKE '%key=%' THEN right(webhook_url, 6) ELSE '' END AS webhook_key_tail,
      enabled, consecutive_failures, disabled_reason, last_push_at, created_at
    FROM public.merchant_wecom_groups
    WHERE root_manager_id = v_root
  ) g;

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.sort_order, t.id), '[]'::jsonb) INTO v_tips
  FROM (
    SELECT id, content, sort_order
    FROM public.merchant_wecom_tips
    WHERE root_manager_id = v_root
  ) t;

  SELECT count(*) INTO v_tip_count
  FROM public.merchant_wecom_tips
  WHERE root_manager_id = v_root;

  RETURN jsonb_build_object(
    'settings', COALESCE(v_settings, '{}'::jsonb),
    'groups', v_groups,
    'tips', v_tips,
    'tip_count', v_tip_count
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_merchant_wecom_config() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_merchant_wecom_config() TO authenticated;

-- ───────────────────────── 5. 配置保存：追加 p_contact_secret（NULL=保持原值，空串=清空） ─────────────────────────
DROP FUNCTION IF EXISTS public.save_merchant_wecom_settings(boolean, text, text, uuid, text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION public.save_merchant_wecom_settings(
  p_scheduled_enabled boolean,
  p_scheduled_time text,
  p_timezone text,
  p_agent_manager_id uuid,
  p_welcome_message text,
  p_single_chat_corp_id text,
  p_single_chat_agent_id text,
  p_single_chat_secret text DEFAULT NULL,
  p_single_chat_token text DEFAULT NULL,
  p_single_chat_aes_key text DEFAULT NULL,
  p_contact_secret text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_time text;
  v_tz text;
  v_welcome text;
  v_tips int;
  v_agent uuid;
  v_agent_ok boolean;
  v_corp_id text;
  v_agent_id text;
  v_secret text;
  v_token text;
  v_aes text;
  v_contact_secret text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_merchant_root(auth.uid()) THEN
    RAISE EXCEPTION '仅企业负责人可配置企业微信' USING ERRCODE = '42501';
  END IF;
  v_root := auth.uid();

  v_time := btrim(COALESCE(p_scheduled_time, '09:00'));
  IF v_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
    RAISE EXCEPTION '推送时间格式应为 HH:MM（如 09:00）' USING ERRCODE = 'P0002';
  END IF;

  v_tz := btrim(COALESCE(p_timezone, 'Asia/Shanghai'));
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = v_tz) THEN
    RAISE EXCEPTION '时区不存在' USING ERRCODE = 'P0002';
  END IF;

  v_welcome := btrim(COALESCE(p_welcome_message, ''));
  IF char_length(v_welcome) > 500 THEN
    RAISE EXCEPTION '欢迎语不能超过 500 字' USING ERRCODE = 'P0002';
  END IF;

  IF COALESCE(p_scheduled_enabled, false) THEN
    SELECT count(*) INTO v_tips FROM public.merchant_wecom_tips WHERE root_manager_id = v_root;
    IF v_tips < 7 THEN
      RAISE EXCEPTION '开启定时推送前，请先准备至少 7 条健康小贴士' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  v_agent := p_agent_manager_id;
  IF v_agent IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.managers m
      WHERE m.id = v_agent
        AND COALESCE(m.is_system_default, false) = false
        AND public.get_profile_enterprise_id(m.id) = public.get_profile_enterprise_id(v_root)
        AND COALESCE(m.public_qa_enabled, false)
    ) INTO v_agent_ok;
    IF NOT v_agent_ok THEN
      RAISE EXCEPTION '承接智能体必须是本企业已开启公开问答的健管师' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  v_corp_id := btrim(COALESCE(p_single_chat_corp_id, ''));
  v_agent_id := btrim(COALESCE(p_single_chat_agent_id, ''));
  IF char_length(v_corp_id) > 64 OR char_length(v_agent_id) > 64 THEN
    RAISE EXCEPTION '企业 ID 或应用 AgentId 长度超出限制' USING ERRCODE = 'P0002';
  END IF;

  v_secret := COALESCE(p_single_chat_secret, '');
  v_token := COALESCE(p_single_chat_token, '');
  v_aes := COALESCE(p_single_chat_aes_key, '');
  v_contact_secret := COALESCE(p_contact_secret, '');
  IF char_length(v_secret) > 512 OR char_length(v_token) > 512
     OR char_length(v_aes) > 512 OR char_length(v_contact_secret) > 512 THEN
    RAISE EXCEPTION '密钥参数长度超出限制' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO public.merchant_wecom_settings
    (root_manager_id, scheduled_enabled, scheduled_time, timezone, agent_manager_id,
     welcome_message, single_chat_corp_id, single_chat_agent_id,
     single_chat_secret, single_chat_token, single_chat_aes_key,
     contact_secret, single_chat_enabled)
  VALUES
    (v_root, COALESCE(p_scheduled_enabled, false), v_time, v_tz, v_agent,
     NULLIF(v_welcome, ''), v_corp_id, v_agent_id,
     NULLIF(v_secret, ''), NULLIF(v_token, ''), NULLIF(v_aes, ''),
     NULLIF(v_contact_secret, ''), false)
  ON CONFLICT (root_manager_id) DO UPDATE
    SET scheduled_enabled = EXCLUDED.scheduled_enabled,
        scheduled_time = EXCLUDED.scheduled_time,
        timezone = EXCLUDED.timezone,
        agent_manager_id = EXCLUDED.agent_manager_id,
        welcome_message = EXCLUDED.welcome_message,
        single_chat_corp_id = COALESCE(NULLIF(EXCLUDED.single_chat_corp_id, ''), merchant_wecom_settings.single_chat_corp_id),
        single_chat_agent_id = COALESCE(NULLIF(EXCLUDED.single_chat_agent_id, ''), merchant_wecom_settings.single_chat_agent_id),
        single_chat_secret = COALESCE(NULLIF(EXCLUDED.single_chat_secret, ''), merchant_wecom_settings.single_chat_secret),
        single_chat_token = COALESCE(NULLIF(EXCLUDED.single_chat_token, ''), merchant_wecom_settings.single_chat_token),
        single_chat_aes_key = COALESCE(NULLIF(EXCLUDED.single_chat_aes_key, ''), merchant_wecom_settings.single_chat_aes_key),
        contact_secret = COALESCE(NULLIF(EXCLUDED.contact_secret, ''), merchant_wecom_settings.contact_secret),
        contact_access_token = CASE
          WHEN NULLIF(EXCLUDED.contact_secret, '') IS NOT NULL
            AND NULLIF(EXCLUDED.contact_secret, '') IS DISTINCT FROM merchant_wecom_settings.contact_secret
          THEN NULL
          ELSE merchant_wecom_settings.contact_access_token
        END,
        contact_token_expires_at = CASE
          WHEN NULLIF(EXCLUDED.contact_secret, '') IS NOT NULL
            AND NULLIF(EXCLUDED.contact_secret, '') IS DISTINCT FROM merchant_wecom_settings.contact_secret
          THEN NULL
          ELSE merchant_wecom_settings.contact_token_expires_at
        END,
        single_chat_callback_verified_at = CASE
          WHEN (NULLIF(EXCLUDED.single_chat_token, '') IS NOT NULL
                AND NULLIF(EXCLUDED.single_chat_token, '') IS DISTINCT FROM merchant_wecom_settings.single_chat_token)
            OR (NULLIF(EXCLUDED.single_chat_aes_key, '') IS NOT NULL
                AND NULLIF(EXCLUDED.single_chat_aes_key, '') IS DISTINCT FROM merchant_wecom_settings.single_chat_aes_key)
          THEN NULL
          ELSE merchant_wecom_settings.single_chat_callback_verified_at
        END,
        single_chat_enabled = false,
        updated_at = now();

  RETURN public.get_merchant_wecom_config();
END;
$function$;

REVOKE ALL ON FUNCTION public.save_merchant_wecom_settings(boolean, text, text, uuid, text, text, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_merchant_wecom_settings(boolean, text, text, uuid, text, text, text, text, text, text, text) TO authenticated;

-- ───────────────────────── 6. 好友列表（企业根 scope，员工持码可看） ─────────────────────────
CREATE OR REPLACE FUNCTION public.list_merchant_wecom_contacts(
  p_limit int DEFAULT 20,
  p_offset int DEFAULT 0,
  p_search text DEFAULT NULL,
  p_type text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_search text;
  v_type text;
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

  v_search := NULLIF(btrim(COALESCE(p_search, '')), '');
  v_type := NULLIF(btrim(COALESCE(p_type, '')), '');
  IF v_type IS NOT NULL AND v_type NOT IN ('kf', 'contact') THEN
    RAISE EXCEPTION '好友类型不合法' USING ERRCODE = '22023';
  END IF;

  SELECT count(*) INTO v_total
  FROM public.merchant_wecom_contacts c
  WHERE c.root_manager_id = v_root
    AND (v_type IS NULL OR c.type = v_type)
    AND (
      v_search IS NULL
      OR c.name ILIKE '%' || v_search || '%'
      OR c.external_userid ILIKE '%' || v_search || '%'
      OR COALESCE(c.unionid, '') ILIKE '%' || v_search || '%'
      OR COALESCE(p2.nickname, '') ILIKE '%' || v_search || '%'
    );

  SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row.last_message_at DESC NULLS LAST, row.id), '[]'::jsonb)
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
      c.last_message_at,
      c.first_seen_at,
      COALESCE(
        (SELECT jsonb_agg(jsonb_build_object('wecomUserid', s.wecom_userid, 'nickname', s.nickname) ORDER BY s.nickname)
         FROM public.profiles s
         WHERE s.wecom_userid = ANY (c.follow_userids)),
        '[]'::jsonb
      ) AS follow_staff
    FROM public.merchant_wecom_contacts c
    LEFT JOIN public.profiles p ON p.id = c.profile_id
    WHERE c.root_manager_id = v_root
      AND (v_type IS NULL OR c.type = v_type)
      AND (
        v_search IS NULL
        OR c.name ILIKE '%' || v_search || '%'
        OR c.external_userid ILIKE '%' || v_search || '%'
        OR COALESCE(c.unionid, '') ILIKE '%' || v_search || '%'
        OR COALESCE(p.nickname, '') ILIKE '%' || v_search || '%'
      )
    ORDER BY c.last_message_at DESC NULLS LAST, c.id
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
    OFFSET GREATEST(COALESCE(p_offset, 0), 0)
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_merchant_wecom_contacts(int, int, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_merchant_wecom_contacts(int, int, text, text) TO authenticated;

-- ───────────────────────── 7. 手动关联 / 解除关联客户 ─────────────────────────
CREATE OR REPLACE FUNCTION public.link_merchant_wecom_contact(
  p_contact_id uuid,
  p_profile_id uuid
)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_contact_root uuid;
  v_profile_root uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  SELECT root_manager_id INTO v_contact_root
  FROM public.merchant_wecom_contacts
  WHERE id = p_contact_id;
  IF v_contact_root IS NULL OR v_contact_root IS DISTINCT FROM v_root THEN
    RAISE EXCEPTION '好友不存在或无权操作' USING ERRCODE = '42501';
  END IF;

  IF p_profile_id IS NOT NULL THEN
    v_profile_root := public.get_enterprise_root_manager_id(p_profile_id);
    IF v_profile_root IS NULL OR v_profile_root IS DISTINCT FROM v_root THEN
      RAISE EXCEPTION '只能关联本企业的客户' USING ERRCODE = '42501';
    END IF;
  END IF;

  UPDATE public.merchant_wecom_contacts
  SET profile_id = p_profile_id, updated_at = now()
  WHERE id = p_contact_id;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.link_merchant_wecom_contact(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.link_merchant_wecom_contact(uuid, uuid) TO authenticated;

-- ───────────────────────── 8. 已关联好友的客户 id 集合（客户列表徽标） ─────────────────────────
CREATE OR REPLACE FUNCTION public.list_merchant_wecom_linked_profile_ids()
RETURNS uuid[]
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

  RETURN COALESCE(
    (SELECT array_agg(DISTINCT profile_id)
     FROM public.merchant_wecom_contacts
     WHERE root_manager_id = v_root AND profile_id IS NOT NULL),
    '{}'::uuid[]
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_merchant_wecom_linked_profile_ids() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_merchant_wecom_linked_profile_ids() TO authenticated;

-- ───────────────────────── 9. 员工企微绑定统计（提醒通道卡片） ─────────────────────────
CREATE OR REPLACE FUNCTION public.get_merchant_wecom_binding_summary()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_total int;
  v_bound int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '请先登录' USING ERRCODE = '28000';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  SELECT count(*),
         count(*) FILTER (WHERE COALESCE(wecom_userid, '') <> '')
  INTO v_total, v_bound
  FROM public.profiles
  WHERE (id = v_root OR parent_manager_id = v_root)
    AND role = 'manager'
    AND COALESCE(is_disabled, false) = false;

  RETURN jsonb_build_object('staff_total', v_total, 'staff_bound', v_bound);
END;
$function$;

REVOKE ALL ON FUNCTION public.get_merchant_wecom_binding_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_merchant_wecom_binding_summary() TO authenticated;

-- ───────────────────────── 10. 活码列表 ─────────────────────────
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
    SELECT id, config_id, qr_code, remark, state, userids, type, scene, status, created_at, updated_at
    FROM public.merchant_wecom_contact_ways
    WHERE root_manager_id = v_root
      AND status = 'active'
  ) w;

  RETURN jsonb_build_object('items', v_items);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_merchant_wecom_contact_ways() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_merchant_wecom_contact_ways() TO authenticated;
