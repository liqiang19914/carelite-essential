-- ─────────────────────────────────────────────────────────────────────
-- 渠道推广修复 + 线索查看
--
-- 1. create_merchant_channel（20260909220000 版）调用了从未定义的
--    public.generate_short_code(integer)，导致新建渠道报错
--    "function public.generate_short_code(integer) does not exist"。
--    补上 base62 随机短码生成器（与渠道码 8 位 [A-Za-z0-9] 规则一致）。
-- 2. 新增 list_merchant_channel_leads：商户查看任务墙收集到的
--    「企业信息」（公司/职位/健康诉求）与「手机号授权」客户记录。
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.generate_short_code(p_length int DEFAULT 8)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = ''
AS $$
DECLARE
  alphabet text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  result text := '';
  len int := LEAST(GREATEST(COALESCE(p_length, 8), 4), 32);
  i int;
BEGIN
  FOR i IN 1..len LOOP
    result := result || substr(alphabet, 1 + floor(random() * 62)::int, 1);
  END LOOP;
  RETURN result;
END;
$$;

REVOKE ALL ON FUNCTION public.generate_short_code(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_short_code(int) TO authenticated, service_role;

-- 20260909220000 想用 plpgsql 全字段版替换 v2 的 sql 精简版 get_merchant_channel_for_code，
-- 但 CREATE OR REPLACE 不能改语言，实际线上仍是精简版（缺 name / landing_config 等）。
-- 这里显式 DROP 后按 220000 的意图重建；该函数仅供 service_role EF 与 SECURITY DEFINER 内部调用。
DROP FUNCTION IF EXISTS public.get_merchant_channel_for_code(text);
CREATE OR REPLACE FUNCTION public.get_merchant_channel_for_code(p_code text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_row public.merchant_channels;
BEGIN
  SELECT * INTO v_row FROM public.merchant_channels WHERE code = p_code LIMIT 1;
  IF v_row IS NULL THEN RETURN NULL; END IF;
  RETURN row_to_json(v_row)::jsonb;
END;
$$;

REVOKE ALL ON FUNCTION public.get_merchant_channel_for_code(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_merchant_channel_for_code(text) TO service_role;

-- ─────────────────────────────────────────────────────────────────────
-- 2. 重建 create / update_merchant_channel
--    20260909220000 版把 p_landing_tasks 声明成 jsonb 却直接写入 text[] 列，
--    新建/编辑渠道在短码问题之后还会报 42804（jsonb → text[]）。
--    入参契约（jsonb）保持不变，函数内转 text[] 并做任务白名单校验。
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.create_merchant_channel(
  p_name text,
  p_category text DEFAULT 'other',
  p_target_page text DEFAULT 'pages/index/index',
  p_remark text DEFAULT NULL,
  p_root_manager_id uuid DEFAULT NULL,
  p_landing_tasks jsonb DEFAULT NULL,
  p_wecom_qr_image_url text DEFAULT NULL,
  p_landing_config jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_root uuid := COALESCE(p_root_manager_id, public.get_enterprise_root_manager_id(auth.uid()));
  v_code text;
  v_tasks text[];
BEGIN
  IF v_root IS NULL THEN RAISE EXCEPTION '未登录或无企业归属' USING ERRCODE = '28000'; END IF;
  IF COALESCE(btrim(p_name), '') = '' THEN RAISE EXCEPTION '渠道名称不能为空' USING ERRCODE = '23505'; END IF;

  v_tasks := CASE WHEN jsonb_typeof(p_landing_tasks) = 'array'
                  THEN ARRAY(SELECT jsonb_array_elements_text(p_landing_tasks))
                  ELSE '{}' END;
  IF NOT (v_tasks <@ ARRAY['wecom_qr','phone_auth','company_info']) THEN
    RAISE EXCEPTION 'landing_tasks 只能包含 wecom_qr / phone_auth / company_info';
  END IF;

  v_code := public.generate_short_code(8);
  WHILE EXISTS (SELECT 1 FROM public.merchant_channels WHERE code = v_code) LOOP
    v_code := public.generate_short_code(8);
  END LOOP;

  INSERT INTO public.merchant_channels (
    code, name, category, target_page, remark, root_manager_id,
    landing_tasks, wecom_qr_image_url, landing_config
  ) VALUES (
    v_code, btrim(p_name), COALESCE(NULLIF(btrim(p_category), ''), 'other'),
    COALESCE(NULLIF(btrim(p_target_page), ''), 'pages/index/index'),
    NULLIF(btrim(COALESCE(p_remark, '')), ''), v_root,
    v_tasks,
    NULLIF(btrim(COALESCE(p_wecom_qr_image_url, '')), ''),
    COALESCE(p_landing_config, '{}'::jsonb)
  );

  RETURN public.get_merchant_channel_for_code(v_code);
END;
$$;

REVOKE ALL ON FUNCTION public.create_merchant_channel(text, text, text, text, uuid, jsonb, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_merchant_channel(text, text, text, text, uuid, jsonb, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_merchant_channel(text, text, text, text, uuid, jsonb, text, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.update_merchant_channel(
  p_code text,
  p_name text DEFAULT NULL,
  p_category text DEFAULT NULL,
  p_target_page text DEFAULT NULL,
  p_remark text DEFAULT NULL,
  p_is_active boolean DEFAULT NULL,
  p_landing_tasks jsonb DEFAULT NULL,
  p_wecom_qr_image_url text DEFAULT NULL,
  p_landing_config jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_root uuid := public.get_enterprise_root_manager_id(auth.uid());
  v_tasks text[];
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.merchant_channels WHERE code = p_code AND root_manager_id = v_root
  ) THEN RAISE EXCEPTION '渠道不存在或无权限' USING ERRCODE = '42501'; END IF;

  IF p_landing_tasks IS NOT NULL THEN
    IF jsonb_typeof(p_landing_tasks) <> 'array' THEN
      RAISE EXCEPTION 'landing_tasks 必须是数组';
    END IF;
    v_tasks := ARRAY(SELECT jsonb_array_elements_text(p_landing_tasks));
    IF NOT (v_tasks <@ ARRAY['wecom_qr','phone_auth','company_info']) THEN
      RAISE EXCEPTION 'landing_tasks 只能包含 wecom_qr / phone_auth / company_info';
    END IF;
  END IF;

  UPDATE public.merchant_channels c SET
    name = COALESCE(NULLIF(btrim(p_name), ''), c.name),
    category = COALESCE(NULLIF(btrim(p_category), ''), c.category),
    target_page = COALESCE(NULLIF(btrim(p_target_page), ''), c.target_page),
    remark = CASE WHEN p_remark IS NULL THEN c.remark ELSE NULLIF(btrim(p_remark), '') END,
    is_active = COALESCE(p_is_active, c.is_active),
    landing_tasks = COALESCE(v_tasks, c.landing_tasks),
    wecom_qr_image_url = CASE
      WHEN p_wecom_qr_image_url IS NULL THEN c.wecom_qr_image_url
      ELSE NULLIF(btrim(p_wecom_qr_image_url), '') END,
    landing_config = COALESCE(p_landing_config, c.landing_config),
    updated_at = now()
  WHERE c.code = p_code;

  RETURN public.get_merchant_channel_for_code(p_code);
END;
$$;

REVOKE ALL ON FUNCTION public.update_merchant_channel(text, text, text, text, text, boolean, jsonb, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_merchant_channel(text, text, text, text, text, boolean, jsonb, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_merchant_channel(text, text, text, text, text, boolean, jsonb, text, jsonb) TO service_role;

-- ─────────────────────────────────────────────────────────────────────
-- 3. 渠道线索：商户查看任务墙收集到的企业信息与手机号授权记录
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.list_merchant_channel_leads(
  p_code text,
  p_kind text DEFAULT 'company_info',
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_total int;
  v_items jsonb;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION '请先登录' USING ERRCODE = '28000'; END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.merchant_channels
    WHERE code = btrim(COALESCE(p_code, '')) AND root_manager_id = v_root
  ) THEN
    RAISE EXCEPTION '渠道不存在或无权操作' USING ERRCODE = '42501';
  END IF;

  IF p_kind = 'phone_auth' THEN
    -- 已归因注册客户（profiles 里的真实手机号，可直接联系）
    WITH signed AS (
      SELECT s.user_id,
             s.created_at,
             s.is_new_user,
             NULLIF(btrim(COALESCE(s.source, '')), '') AS source,
             NULLIF(btrim(p.phone), '') AS phone,
             COALESCE(NULLIF(btrim(p.real_name), ''), NULLIF(btrim(p.nickname), '')) AS name
      FROM public.merchant_channel_signups s
      JOIN public.profiles p ON p.id = s.user_id
      WHERE s.channel_code = btrim(p_code)
    ),
    -- bind_phone 任务记录：同一人可能有 visitor 行 + user 行、换 visitor_key 重复授权，
    -- 优先取 user 行；匿名行按脱敏手机号去重，无脱敏号再按 visitor_key
    task_users AS (
      SELECT DISTINCT ON (
        COALESCE(
          t.user_id::text,
          CASE WHEN NULLIF(btrim(t.extra->>'phone_masked'), '') IS NOT NULL
               THEN 'p:' || NULLIF(btrim(t.extra->>'phone_masked'), '')
               ELSE 'v:' || t.visitor_key END
        )
      )
             t.user_id, t.visitor_key, t.completed_at,
             NULLIF(btrim(t.extra->>'phone_masked'), '') AS phone_masked
      FROM public.merchant_channel_tasks t
      WHERE t.channel_code = btrim(p_code)
        AND t.task_name = 'phone_auth'
        AND (t.user_id IS NOT NULL OR t.visitor_key IS NOT NULL)
      ORDER BY COALESCE(
                 t.user_id::text,
                 CASE WHEN NULLIF(btrim(t.extra->>'phone_masked'), '') IS NOT NULL
                      THEN 'p:' || NULLIF(btrim(t.extra->>'phone_masked'), '')
                      ELSE 'v:' || t.visitor_key END
               ),
               (t.user_id IS NOT NULL) DESC, t.completed_at DESC
    ),
    all_leads AS (
      SELECT user_id AS uid, created_at, is_new_user,
             COALESCE(source, 'unknown') AS source,
             phone, name, 'signup'::text AS lead_type
      FROM signed
      UNION ALL
      -- 注册归因之外的授权记录（如原生页一键授权后未触发归因）：
      -- 同 user 已在 signed 里则剔除；脱敏号与 signed 真实号同源也剔除，避免重复
      SELECT tu.user_id, tu.completed_at, NULL::boolean, 'phone_auth',
             COALESCE(NULLIF(btrim(p.phone), ''), tu.phone_masked),
             COALESCE(NULLIF(btrim(p.real_name), ''), NULLIF(btrim(p.nickname), '')),
             'phone_task'
      FROM task_users tu
      LEFT JOIN public.profiles p ON p.id = tu.user_id
      WHERE (tu.user_id IS NULL
             OR NOT EXISTS (SELECT 1 FROM signed sg WHERE sg.user_id = tu.user_id))
        AND (tu.phone_masked IS NULL
             OR NOT EXISTS (
               SELECT 1 FROM signed sg
               WHERE sg.phone IS NOT NULL
                 AND left(sg.phone, 3) = left(tu.phone_masked, 3)
                 AND right(sg.phone, 4) = right(tu.phone_masked, 4)
             ))
    ),
    page AS (
      SELECT uid, phone, name, is_new_user, source, lead_type, created_at
      FROM all_leads
      ORDER BY created_at DESC
      LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
      OFFSET GREATEST(COALESCE(p_offset, 0), 0)
    )
    SELECT (SELECT count(*) FROM all_leads),
           COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC)
                     FROM (SELECT * FROM page) r), '[]'::jsonb)
    INTO v_total, v_items;
  ELSE
    -- company_info：每个客户（user 或 visitor）取最新一次提交
    WITH t_rows AS (
      SELECT DISTINCT ON (COALESCE(t.user_id::text, 'v:' || t.visitor_key))
             t.user_id, t.completed_at, t.extra
      FROM public.merchant_channel_tasks t
      WHERE t.channel_code = btrim(p_code)
        AND t.task_name = 'company_info'
        AND (t.user_id IS NOT NULL OR t.visitor_key IS NOT NULL)
        AND (
          NULLIF(btrim(t.extra->>'company'), '') IS NOT NULL
          OR NULLIF(btrim(t.extra->>'position'), '') IS NOT NULL
          OR NULLIF(btrim(t.extra->>'health_need'), '') IS NOT NULL
        )
      ORDER BY COALESCE(t.user_id::text, 'v:' || t.visitor_key),
               (t.user_id IS NOT NULL) DESC, t.completed_at DESC
    ),
    page AS (
      SELECT NULLIF(btrim(t.extra->>'company'), '') AS company,
             NULLIF(btrim(t.extra->>'position'), '') AS position,
             NULLIF(btrim(t.extra->>'health_need'), '') AS health_need,
             NULLIF(btrim(p.phone), '') AS phone,
             COALESCE(NULLIF(btrim(p.real_name), ''), NULLIF(btrim(p.nickname), '')) AS name,
             t.completed_at AS created_at
      FROM t_rows t
      LEFT JOIN public.profiles p ON p.id = t.user_id
      ORDER BY t.completed_at DESC
      LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
      OFFSET GREATEST(COALESCE(p_offset, 0), 0)
    )
    SELECT (SELECT count(*) FROM t_rows),
           COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.created_at DESC)
                     FROM (SELECT * FROM page) r), '[]'::jsonb)
    INTO v_total, v_items;
  END IF;

  RETURN jsonb_build_object('items', v_items, 'total', COALESCE(v_total, 0));
END;
$$;

REVOKE ALL ON FUNCTION public.list_merchant_channel_leads(text, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_merchant_channel_leads(text, text, int, int) TO authenticated;

NOTIFY pgrst, 'reload schema';
