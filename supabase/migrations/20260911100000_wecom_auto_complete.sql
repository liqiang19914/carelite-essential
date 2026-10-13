-- ─────────────────────────────────────────────────────────────────────
-- 渠道推广：加企微好友"自动完成"（手机号匹配）
--
-- 现状：wecom_qr 任务依赖客户手动点"标记完成"；但其实企微客户库
-- merchant_wecom_contacts 已经能证明这个人"加过任何一个顾问的企微"
-- （follow_userids 非空 + 有 mobile 手机号）。
-- 缺口：merchant_wecom_contacts 没有 phone 列（企微 API 能返回 mobile，
-- 但 upsertExternalContact 没存）；landing RPC 的 completed_tasks 判断
-- 只看 merchant_channel_tasks 表，没有企微客户库自动完成的逻辑。
--
-- 改动：
--   1. merchant_wecom_contacts 加 phone text 列
--   2. upsertExternalContact 存企微 mobile（手动同步路径）
--   3. hydrateContactAvatarAndName 回调补资料时也存 mobile（自动同步路径）
--   4. get_merchant_channel_landing 的 completed_tasks 里，新增
--      "profile.phone 匹配企微 contacts.phone（同 root + follow_userids 非空）"
--      → wecom_qr 自动完成；"profile_id 已关联企微好友"也自动完成；
--      "企微好友 unionid 匹配 profile.wechat_unionid" 同样自动完成
--   5. 存量回填：对现有 15867 条带 unionid 的企微好友，若 follow_userids
--      非空且 profile_id 为 NULL，再补一次 profile_id（通过 unionid 匹配）
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.merchant_wecom_contacts
  ADD COLUMN IF NOT EXISTS phone text;

CREATE INDEX IF NOT EXISTS mwec_phone_root_idx
  ON public.merchant_wecom_contacts(root_manager_id, phone)
  WHERE phone IS NOT NULL AND phone <> '';

-- ── 一次性存量回填：用企微 contacts 的 unionid 反查 profiles ──────────
-- 只对 follow_userids 非空 + profile_id IS NULL + unionid 非空 的跑；
-- 命中就把 profile_id 补上。数据量小（15867 里 profile_id 只有 1 条非空，
-- 但 unionid 有 15867 条），一次性 UPDATE 安全。
UPDATE public.merchant_wecom_contacts c
SET profile_id = p.id,
    updated_at = now()
FROM public.profiles p
WHERE c.profile_id IS NULL
  AND c.unionid IS NOT NULL AND c.unionid <> ''
  AND c.follow_userids IS NOT NULL
  AND array_length(c.follow_userids, 1) > 0
  AND c.root_manager_id = (
    SELECT COALESCE(p2.parent_manager_id, p2.id)
    FROM public.profiles p2 WHERE p2.id = p.id
  )::uuid
  AND p.wechat_unionid IS NOT NULL
  AND p.wechat_unionid = c.unionid;

-- ── 更新 landing RPC：wecom_qr 自动完成判断追加 ──────────────────────
CREATE OR REPLACE FUNCTION public.get_merchant_channel_landing(
  p_code text,
  p_visitor_key text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_root uuid;
  v_channel jsonb;
  v_brand_name text;
  v_done jsonb;
  v_images jsonb := '[]'::jsonb;
  v_n int;
  v_idx int;
  v_seed text;
  v_qr text;
BEGIN
  SELECT to_jsonb(c) INTO v_channel
  FROM public.merchant_channels c
  WHERE c.code = p_code AND c.is_active = true;

  IF v_channel IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'NOT_FOUND');
  END IF;

  v_root := v_channel->>'root_manager_id';
  SELECT COALESCE(m.brand_name, m.app_name, '') INTO v_brand_name
  FROM public.manager_miniprograms m
  WHERE m.manager_id = v_root AND m.is_enabled = true
  LIMIT 1;

  -- ── 已完成任务：优先从 merchant_channel_tasks 表取（显式标记） ────
  -- 再加两层自动完成兜底：
  --   a) 当前登录用户的 profile_id 直接匹配企微好友
  --   b) profile.phone 匹配企微 contacts.phone（follow_userids 非空 = 加过任意顾问）
  --   c) 企微 contacts.unionid 匹配 profile.wechat_unionid（跨平台兜底）
  IF auth.uid() IS NOT NULL THEN
    WITH
    explicit AS (
      SELECT DISTINCT task_name FROM public.merchant_channel_tasks
      WHERE channel_code = p_code
        AND (
          user_id = auth.uid()
          OR (p_visitor_key IS NOT NULL AND visitor_key = p_visitor_key)
        )
    ),
    auto_done AS (
      SELECT 'wecom_qr'::text AS task_name
      FROM public.merchant_wecom_contacts c
      WHERE c.root_manager_id = v_root::uuid
        AND c.follow_userids IS NOT NULL
        AND array_length(c.follow_userids, 1) > 0
        AND (
          c.profile_id = auth.uid()
          OR (
            c.phone IS NOT NULL AND c.phone <> ''
            AND EXISTS (
              SELECT 1 FROM public.profiles p
              WHERE p.id = auth.uid() AND p.phone = c.phone AND p.phone <> ''
            )
          )
          OR (
            c.unionid IS NOT NULL AND c.unionid <> ''
            AND EXISTS (
              SELECT 1 FROM public.profiles p
              WHERE p.id = auth.uid()
                AND p.wechat_unionid = c.unionid
                AND p.wechat_unionid <> ''
            )
          )
        )
      LIMIT 1
    ),
    phone_auth AS (
      SELECT 'phone_auth'::text AS task_name
      WHERE EXISTS (
        SELECT 1 FROM public.profiles WHERE id = auth.uid()
          AND COALESCE(btrim(phone), '') <> ''
      )
    ),
    union_done AS (
      SELECT DISTINCT task_name FROM (
        SELECT task_name FROM explicit
        UNION ALL SELECT task_name FROM auto_done
        UNION ALL SELECT task_name FROM phone_auth
      ) d
    )
    SELECT COALESCE(jsonb_agg(task_name ORDER BY task_name), '[]'::jsonb)
    INTO v_done FROM union_done;
  ELSIF p_visitor_key IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(task_name), '[]'::jsonb) INTO v_done
    FROM (
      SELECT DISTINCT task_name FROM public.merchant_channel_tasks
      WHERE channel_code = p_code AND visitor_key = p_visitor_key
    ) sub;
  ELSE
    v_done := '[]'::jsonb;
  END IF;

  -- 归一化有效二维码：多图列优先，空则回退旧单图字段
  SELECT COALESCE(jsonb_agg(e), '[]'::jsonb) INTO v_images
  FROM jsonb_array_elements(COALESCE(v_channel->'wecom_qr_images', '[]'::jsonb)) e
  WHERE jsonb_typeof(e) = 'string' AND btrim(e #>> '{}') <> '';

  IF jsonb_array_length(v_images) = 0 AND COALESCE(btrim(v_channel->>'wecom_qr_image_url'), '') <> '' THEN
    v_images := jsonb_build_array(v_channel->>'wecom_qr_image_url');
  END IF;

  v_n := jsonb_array_length(v_images);
  IF v_n > 0 THEN
    v_seed := COALESCE(NULLIF(btrim(COALESCE(p_visitor_key, '')), ''), auth.uid()::text);
    IF v_seed IS NOT NULL THEN
      v_idx := abs(hashtextextended(v_seed, 0)) % v_n;
    ELSE
      v_idx := floor(random() * v_n)::int;
    END IF;
    v_qr := v_images ->> v_idx;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'skip', COALESCE(jsonb_array_length(COALESCE(v_channel->'landing_tasks', '[]'::jsonb)), 0) = 0,
    'channel', jsonb_build_object(
      'code', v_channel->>'code',
      'name', v_channel->>'name',
      'landing_enabled', COALESCE((v_channel->>'landing_enabled')::boolean, true),
      'landing_tasks', COALESCE(v_channel->'landing_tasks', '[]'::jsonb),
      'landing_config', COALESCE(v_channel->'landing_config', '{}'::jsonb),
      'wecom_qr_image_url', v_qr,
      'wecom_qr_count', v_n
    ),
    'brand', jsonb_build_object('name', v_brand_name),
    'completed_tasks', v_done
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';
