-- 企微超级助手 P0：群发合规预检 + 今日额度 + 防打扰频控 + 全选全部匹配 + 任务明细/失败补发 + 话术模板库
--
-- 1) 敏感词分级：hard=硬阻断（医疗承诺/广告法违禁等平台词），soft=二次确认（商户自加词、飞单词）
--    原有 14 个平台种子词中「保证治愈/百分百见效」升级为 hard，其余飞单词对个人微信外挂仅提示。

ALTER TABLE public.merchant_wecom_sensitive_words
  ADD COLUMN IF NOT EXISTS level text NOT NULL DEFAULT 'soft';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'mw_sensitive_level_check'
  ) THEN
    ALTER TABLE public.merchant_wecom_sensitive_words
      ADD CONSTRAINT mw_sensitive_level_check CHECK (level IN ('hard', 'soft'));
  END IF;
END $$;

UPDATE public.merchant_wecom_sensitive_words
SET level = 'hard'
WHERE root_manager_id IS NULL
  AND word IN ('保证治愈', '百分百见效');

-- 平台硬禁词种子（医疗营销承诺 / 广告法极限词 / 传销诈骗风险），与既有飞单软提示词分开
INSERT INTO public.merchant_wecom_sensitive_words (root_manager_id, scope, word, level)
SELECT NULL, 'platform', w.word, 'hard'
FROM (VALUES
  ('根治'), ('包治'), ('治愈'), ('断根'), ('药到病除'), ('无副作用'),
  ('百分百有效'), ('100%有效'), ('零风险'), ('无风险'), ('永不复发'),
  ('无效退款'), ('祖传秘方'), ('神医'), ('特效药'), ('防癌'), ('抗癌'),
  ('消瘤'), ('壮阳'), ('最高级'), ('最佳'), ('第一品牌'), ('国家级'),
  ('特供'), ('纯天然制品'), ('治病'), ('转阴')
) AS w(word)
ON CONFLICT DO NOTHING;

-- ───────────────────────── 2. 今日发送额度（北京日，文本+附件按条计，与 cron 口径一致） ─────────────────────────
CREATE OR REPLACE FUNCTION public.get_wecom_super_send_quota()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
  v_used int;
  v_cap int;
BEGIN
  SELECT count(*)::int INTO v_used
  FROM public.wecom_super_messages
  WHERE root_manager_id = v_root
    AND direction = 'out'
    AND msg_time >= (now() AT TIME ZONE 'Asia/Shanghai')::date AT TIME ZONE 'Asia/Shanghai';

  SELECT COALESCE(daily_send_cap, 200) INTO v_cap
  FROM public.wecom_super_platform_config WHERE id = 1;

  v_cap := COALESCE(v_cap, 200);

  RETURN jsonb_build_object(
    'used', v_used,
    'cap', v_cap,
    'remaining', GREATEST(v_cap - v_used, 0)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_wecom_super_send_quota() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wecom_super_send_quota() TO authenticated;

-- ───────────────────────── 3. 近期已私信联系的好友（防打扰频控，默认排除近 7 天） ─────────────────────────
-- 口径：本商户任意云设备近 N 天 direction=out、peer_type=contact 的消息（含群发/单发/自动回复）
CREATE OR REPLACE FUNCTION public.list_wecom_super_recent_contacts(
  p_days int DEFAULT 7
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
  v_days int := LEAST(GREATEST(COALESCE(p_days, 7), 1), 90);
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(DISTINCT peer_id)
    FROM public.wecom_super_messages
    WHERE root_manager_id = v_root
      AND direction = 'out'
      AND peer_type = 'contact'
      AND msg_time >= now() - make_interval(days => v_days)
  ), '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_recent_contacts(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_recent_contacts(int) TO authenticated;

-- ───────────────────────── 4. 按筛选条件取全部好友 ID（「全选全部匹配」用，上限 2000） ─────────────────────────
CREATE OR REPLACE FUNCTION public.list_wecom_super_contact_ids(
  p_keyword text DEFAULT NULL,
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
    SELECT c.external_userid AS "externalUserid",
           COALESCE(c.name, c.external_userid) AS name
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
      ))
    ORDER BY c.synced_at DESC NULLS LAST, c.created_at DESC
    LIMIT 2000
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_contact_ids(text, text, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_contact_ids(text, text, text[]) TO authenticated;

-- ───────────────────────── 5. 按筛选条件取全部群 ID ─────────────────────────
CREATE OR REPLACE FUNCTION public.list_wecom_super_room_ids(
  p_keyword text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_root uuid := public._wecom_super_guard();
  v_keyword text := NULLIF(btrim(COALESCE(p_keyword, '')), '');
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
    SELECT r.room_id AS "roomId", COALESCE(r.name, r.room_id) AS name
    FROM public.wecom_super_rooms r
    WHERE r.root_manager_id = v_root
      AND (v_keyword IS NULL
           OR COALESCE(r.name, '') ILIKE '%' || v_keyword || '%'
           OR r.room_id ILIKE '%' || v_keyword || '%')
    ORDER BY r.synced_at DESC NULLS LAST, r.created_at DESC
    LIMIT 2000
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_room_ids(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_room_ids(text) TO authenticated;

-- ───────────────────────── 6. 任务发送明细（成功/失败/待发名单 + 失败原因） ─────────────────────────
CREATE OR REPLACE FUNCTION public.list_wecom_super_task_items(
  p_task_id uuid,
  p_status text DEFAULT NULL,
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
  v_status text := NULLIF(btrim(COALESCE(p_status, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_page_size, 50), 1), 200);
  v_offset int := (GREATEST(COALESCE(p_page, 1), 1) - 1) * v_limit;
  v_target_type text;
  v_total int;
  v_sent int;
  v_failed int;
  v_pending int;
  v_items jsonb;
BEGIN
  SELECT target_type INTO v_target_type
  FROM public.wecom_super_send_tasks
  WHERE id = p_task_id AND root_manager_id = v_root;

  IF v_target_type IS NULL THEN
    RAISE EXCEPTION '任务不存在' USING ERRCODE = 'P0002';
  END IF;

  SELECT
    count(*),
    count(*) FILTER (WHERE i.status = 'sent'),
    count(*) FILTER (WHERE i.status = 'failed'),
    count(*) FILTER (WHERE i.status = 'pending')
  INTO v_total, v_sent, v_failed, v_pending
  FROM public.wecom_super_send_items i
  WHERE i.task_id = p_task_id
    AND (v_status IS NULL OR i.status = v_status);

  SELECT COALESCE(jsonb_agg(to_jsonb(row)), '[]'::jsonb) INTO v_items
  FROM (
    SELECT i.target_id AS "targetId",
           i.status,
           i.error,
           i.sent_at AS "sentAt",
           CASE WHEN v_target_type = 'room' THEN p.name ELSE c.name END AS name,
           CASE WHEN v_target_type = 'room' THEN p.avatar_url ELSE c.avatar_url END AS "avatarUrl"
    FROM public.wecom_super_send_items i
    LEFT JOIN LATERAL (
      SELECT c1.name, c1.avatar_url
      FROM public.wecom_super_contacts c1
      WHERE c1.root_manager_id = v_root AND c1.external_userid = i.target_id
      ORDER BY c1.synced_at DESC NULLS LAST
      LIMIT 1
    ) c ON v_target_type = 'contact'
    LEFT JOIN LATERAL (
      SELECT r1.name, r1.avatar_url
      FROM public.wecom_super_rooms r1
      WHERE r1.root_manager_id = v_root AND r1.room_id = i.target_id
      ORDER BY r1.synced_at DESC NULLS LAST
      LIMIT 1
    ) p ON v_target_type = 'room'
    WHERE i.task_id = p_task_id
      AND (v_status IS NULL OR i.status = v_status)
    ORDER BY
      CASE i.status WHEN 'failed' THEN 1 WHEN 'pending' THEN 2 ELSE 3 END,
      i.sent_at DESC NULLS LAST,
      i.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) row;

  RETURN jsonb_build_object(
    'items', v_items,
    'total', v_total,
    'counts', jsonb_build_object('sent', v_sent, 'failed', v_failed, 'pending', v_pending)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_super_task_items(uuid, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_super_task_items(uuid, text, int, int) TO authenticated;

-- ───────────────────────── 7. 话术模板库 ─────────────────────────
CREATE TABLE IF NOT EXISTS public.wecom_super_message_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  title text NOT NULL,
  content text NOT NULL DEFAULT '',
  scene text NOT NULL DEFAULT 'all',                 -- private | group | all
  category text,
  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT wecom_super_tpl_title_check CHECK (char_length(btrim(title)) BETWEEN 1 AND 100),
  CONSTRAINT wecom_super_tpl_content_check CHECK (char_length(content) BETWEEN 0 AND 2000),
  CONSTRAINT wecom_super_tpl_scene_check CHECK (scene IN ('private', 'group', 'all'))
);

CREATE INDEX IF NOT EXISTS idx_wecom_super_templates_root
  ON public.wecom_super_message_templates (root_manager_id, updated_at DESC);

ALTER TABLE public.wecom_super_message_templates ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.wecom_super_message_templates FROM anon, authenticated;
