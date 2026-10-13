-- 企微助手 Pro Task 12-14：
-- 12) 新客欢迎语：模板 + 发送记录 + 回调 WelcomeCode 触发
-- 13) 客户群发：任务 + 回执明细（EF create + cron sync）
-- 14) 客户群：群 + 成员同步（EF sync）
-- 全部走 root_manager_id 隔离 + RLS + REVOKE + SECURITY DEFINER RPC（search_path = ''）；
-- 写操作类 RPC 用 is_merchant_root() 守门，读取类用 get_enterprise_root_manager_id() 收口，
-- 普通员工仅看自己承接的数据。

-- ═════════════════════════ Task 12: 新客欢迎语 ═════════════════════════

CREATE TABLE IF NOT EXISTS public.merchant_wecom_welcome_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  name text NOT NULL,
  content text NOT NULL DEFAULT '',
  -- attachments: [{ type: 'image'|'link'|'miniprogram', ossKey?, url?, title?, desc?, picUrl?, ... }]
  attachments jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_default boolean NOT NULL DEFAULT false,
  -- 渠道专用：绑定 contact_way 的 config_id；为 NULL 表示通用模板
  contact_way_id text,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.merchant_wecom_welcome_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  external_userid text NOT NULL,
  template_id uuid,
  template_name text,
  success boolean NOT NULL DEFAULT false,
  errmsg text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_wecom_welcome_tpls_root
  ON public.merchant_wecom_welcome_templates (root_manager_id, enabled, is_default);
CREATE INDEX IF NOT EXISTS idx_wecom_welcome_logs_root_ext
  ON public.merchant_wecom_welcome_logs (root_manager_id, external_userid, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wecom_welcome_logs_created
  ON public.merchant_wecom_welcome_logs (root_manager_id, created_at DESC);

ALTER TABLE public.merchant_wecom_welcome_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.merchant_wecom_welcome_logs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.merchant_wecom_welcome_templates FROM anon, authenticated;
REVOKE ALL ON public.merchant_wecom_welcome_logs FROM anon, authenticated;

-- 同一商户只能有一个 is_default 模板（部分唯一索引，仅 enabled 模板参与）
CREATE UNIQUE INDEX IF NOT EXISTS uq_wecom_welcome_default
  ON public.merchant_wecom_welcome_templates (root_manager_id)
  WHERE is_default = true AND COALESCE(contact_way_id, '') = '';

-- ── 欢迎语模板列表 ──
CREATE OR REPLACE FUNCTION public.list_wecom_pro_welcome_templates()
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
  IF NOT public.has_enterprise_permission('wecom_pro_welcome', v_uid) THEN
    RAISE EXCEPTION '没有访问欢迎语的权限' USING ERRCODE = '42501';
  END IF;

  RETURN COALESCE(
    (
      SELECT jsonb_agg(jsonb_build_object(
        'id', t.id,
        'name', t.name,
        'content', t.content,
        'attachments', t.attachments,
        'isDefault', t.is_default,
        'contactWayId', t.contact_way_id,
        'enabled', t.enabled,
        'createdAt', t.created_at,
        'updatedAt', t.updated_at,
        'contactWayName', cw.remark
      ) ORDER BY t.is_default DESC, t.created_at DESC)
      FROM public.merchant_wecom_welcome_templates t
      LEFT JOIN public.merchant_wecom_contact_ways cw
        ON cw.root_manager_id = t.root_manager_id AND cw.config_id = t.contact_way_id
      WHERE t.root_manager_id = v_root
    ),
    '[]'::jsonb
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_pro_welcome_templates() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_pro_welcome_templates() TO authenticated;

-- ── 保存欢迎语模板（新建 / 编辑）──
CREATE OR REPLACE FUNCTION public.save_wecom_pro_welcome_template(
  p_id uuid DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_content text DEFAULT NULL,
  p_attachments jsonb DEFAULT NULL,
  p_is_default boolean DEFAULT NULL,
  p_contact_way_id text DEFAULT NULL,
  p_enabled boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_id uuid;
  v_name text;
  v_content text;
  v_attachments jsonb;
  v_is_default boolean;
  v_contact_way_id text;
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
  IF NOT public.has_enterprise_permission('wecom_pro_welcome', v_uid) THEN
    RAISE EXCEPTION '没有管理欢迎语的权限' USING ERRCODE = '42501';
  END IF;

  v_name := NULLIF(btrim(COALESCE(p_name, '')), '');
  IF v_name IS NULL THEN
    RAISE EXCEPTION '请填写模板名称' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_name) > 32 THEN
    RAISE EXCEPTION '模板名称不能超过 32 字' USING ERRCODE = '22023';
  END IF;
  v_content := COALESCE(p_content, '');
  IF char_length(v_content) > 1500 THEN
    RAISE EXCEPTION '欢迎语内容不能超过 1500 字' USING ERRCODE = '22023';
  END IF;
  v_attachments := COALESCE(p_attachments, '[]'::jsonb);
  v_is_default := COALESCE(p_is_default, false);
  v_contact_way_id := NULLIF(btrim(COALESCE(p_contact_way_id, '')), '');

  -- 设为默认前先清除既有默认（同商户通用模板唯一默认）
  IF v_is_default AND v_contact_way_id IS NULL THEN
    UPDATE public.merchant_wecom_welcome_templates
    SET is_default = false, updated_at = now()
    WHERE root_manager_id = v_root
      AND is_default = true
      AND COALESCE(contact_way_id, '') = '';
  END IF;

  IF p_id IS NOT NULL THEN
    UPDATE public.merchant_wecom_welcome_templates
    SET name = v_name,
        content = v_content,
        attachments = v_attachments,
        is_default = v_is_default,
        contact_way_id = v_contact_way_id,
        enabled = COALESCE(p_enabled, true),
        updated_at = now()
    WHERE id = p_id::uuid AND root_manager_id = v_root
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      RAISE EXCEPTION '模板不存在或无权编辑' USING ERRCODE = '42501';
    END IF;
  ELSE
    INSERT INTO public.merchant_wecom_welcome_templates
      (root_manager_id, name, content, attachments, is_default, contact_way_id, enabled)
    VALUES (v_root, v_name, v_content, v_attachments, v_is_default, v_contact_way_id, COALESCE(p_enabled, true))
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object('id', v_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.save_wecom_pro_welcome_template(uuid, text, text, jsonb, boolean, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_wecom_pro_welcome_template(uuid, text, text, jsonb, boolean, text, boolean) TO authenticated;

-- ── 删除欢迎语模板 ──
CREATE OR REPLACE FUNCTION public.delete_wecom_pro_welcome_template(p_id uuid)
RETURNS void
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
  IF NOT public.has_enterprise_permission('wecom_pro_welcome', v_uid) THEN
    RAISE EXCEPTION '没有管理欢迎语的权限' USING ERRCODE = '42501';
  END IF;

  DELETE FROM public.merchant_wecom_welcome_templates
  WHERE id = p_id AND root_manager_id = v_root;
  IF NOT FOUND THEN
    RAISE EXCEPTION '模板不存在或无权删除' USING ERRCODE = '42501';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_wecom_pro_welcome_template(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_wecom_pro_welcome_template(uuid) TO authenticated;

-- ── 欢迎语发送记录 ──
CREATE OR REPLACE FUNCTION public.list_wecom_pro_welcome_logs(
  p_external_userid text DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
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
  IF NOT public.has_enterprise_permission('wecom_pro_welcome', v_uid) THEN
    RAISE EXCEPTION '没有访问欢迎语的权限' USING ERRCODE = '42501';
  END IF;

  SELECT count(*) INTO v_total
  FROM public.merchant_wecom_welcome_logs l
  WHERE l.root_manager_id = v_root
    AND (p_external_userid IS NULL OR l.external_userid = p_external_userid);

  SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row.created_at DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT l.id, l.external_userid, l.template_id, l.template_name,
           l.success, l.errmsg, l.created_at
    FROM public.merchant_wecom_welcome_logs l
    WHERE l.root_manager_id = v_root
      AND (p_external_userid IS NULL OR l.external_userid = p_external_userid)
    ORDER BY l.created_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100)
    OFFSET (GREATEST(COALESCE(p_page, 1), 1) - 1) * LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100)
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_pro_welcome_logs(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_pro_welcome_logs(text, int, int) TO authenticated;


-- ═════════════════════════ Task 13: 客户群发 ═════════════════════════

CREATE TABLE IF NOT EXISTS public.merchant_wecom_mass_tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  -- 企微 add_msg_template 返回的 msgid，提交后回填
  msgid text,
  name text NOT NULL DEFAULT '',
  content text NOT NULL DEFAULT '',
  attachments jsonb NOT NULL DEFAULT '[]'::jsonb,
  -- target_filter: { scope: 'all'|'tag'|'staff', tagIds: [], staffUserids: [] }
  target_filter jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid NOT NULL REFERENCES public.profiles(id),
  -- pending: 初始；sending: 已提交企微；syncing: 同步回执中；done: 全部完成；fail: 提交失败
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sending','syncing','done','fail')),
  total_count int NOT NULL DEFAULT 0,
  sent_count int NOT NULL DEFAULT 0,
  fail_count int NOT NULL DEFAULT 0,
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.merchant_wecom_mass_results (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  task_id uuid NOT NULL REFERENCES public.merchant_wecom_mass_tasks(id) ON DELETE CASCADE,
  userid text NOT NULL,
  external_userid text NOT NULL,
  -- pending / sent / fail / unknown
  send_status text NOT NULL DEFAULT 'pending' CHECK (send_status IN ('pending','sent','fail','unknown')),
  fail_reason text,
  synced_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_mass_result UNIQUE (root_manager_id, task_id, external_userid)
);

CREATE INDEX IF NOT EXISTS idx_wecom_mass_tasks_root
  ON public.merchant_wecom_mass_tasks (root_manager_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wecom_mass_results_task
  ON public.merchant_wecom_mass_results (task_id, send_status);
CREATE INDEX IF NOT EXISTS idx_wecom_mass_results_root_userid
  ON public.merchant_wecom_mass_results (root_manager_id, userid);

ALTER TABLE public.merchant_wecom_mass_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.merchant_wecom_mass_results ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.merchant_wecom_mass_tasks FROM anon, authenticated;
REVOKE ALL ON public.merchant_wecom_mass_results FROM anon, authenticated;

-- ── 群发任务列表 ──
CREATE OR REPLACE FUNCTION public.list_wecom_pro_mass_tasks(
  p_status text DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
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
  IF NOT public.has_enterprise_permission('wecom_pro_massmsg', v_uid) THEN
    RAISE EXCEPTION '没有访问客户群发的权限' USING ERRCODE = '42501';
  END IF;

  SELECT count(*) INTO v_total
  FROM public.merchant_wecom_mass_tasks t
  WHERE t.root_manager_id = v_root
    AND (p_status IS NULL OR t.status = p_status);

  SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row.created_at DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT t.id, t.name, t.content, t.attachments, t.target_filter,
           t.status, t.total_count, t.sent_count, t.fail_count, t.error,
           t.msgid, t.created_at, t.updated_at,
           COALESCE(p.nickname, '') AS created_by_name
    FROM public.merchant_wecom_mass_tasks t
    LEFT JOIN public.profiles p ON p.id = t.created_by
    WHERE t.root_manager_id = v_root
      AND (p_status IS NULL OR t.status = p_status)
    ORDER BY t.created_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100)
    OFFSET (GREATEST(COALESCE(p_page, 1), 1) - 1) * LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100)
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_pro_mass_tasks(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_pro_mass_tasks(text, int, int) TO authenticated;

-- ── 群发任务详情（含进度统计 + 员工明细）──
CREATE OR REPLACE FUNCTION public.get_wecom_pro_mass_task_detail(p_task_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_task public.merchant_wecom_mass_tasks%ROWTYPE;
  v_staff jsonb;
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
  IF NOT public.has_enterprise_permission('wecom_pro_massmsg', v_uid) THEN
    RAISE EXCEPTION '没有访问客户群发的权限' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_task
  FROM public.merchant_wecom_mass_tasks
  WHERE id = p_task_id AND root_manager_id = v_root;
  IF v_task.id IS NULL THEN
    RAISE EXCEPTION '任务不存在或无权查看' USING ERRCODE = '42501';
  END IF;

  -- 按承接员工汇总进度
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'userid', r.userid,
    'total', r.total,
    'sent', r.sent,
    'fail', r.fail,
    'pending', r.pending
  ) ORDER BY r.userid), '[]'::jsonb) INTO v_staff
  FROM (
    SELECT userid,
      count(*) AS total,
      count(*) FILTER (WHERE send_status = 'sent') AS sent,
      count(*) FILTER (WHERE send_status = 'fail') AS fail,
      count(*) FILTER (WHERE send_status = 'pending') AS pending
    FROM public.merchant_wecom_mass_results
    WHERE task_id = v_task.id
    GROUP BY userid
  ) r;

  RETURN jsonb_build_object(
    'id', v_task.id,
    'name', v_task.name,
    'content', v_task.content,
    'attachments', v_task.attachments,
    'targetFilter', v_task.target_filter,
    'status', v_task.status,
    'totalCount', v_task.total_count,
    'sentCount', v_task.sent_count,
    'failCount', v_task.fail_count,
    'error', v_task.error,
    'msgid', v_task.msgid,
    'createdAt', v_task.created_at,
    'updatedAt', v_task.updated_at,
    'staffProgress', v_staff
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_wecom_pro_mass_task_detail(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wecom_pro_mass_task_detail(uuid) TO authenticated;

-- ── 群发回执明细 ──
CREATE OR REPLACE FUNCTION public.list_wecom_pro_mass_results(
  p_task_id uuid,
  p_status text DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
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
  IF NOT public.has_enterprise_permission('wecom_pro_massmsg', v_uid) THEN
    RAISE EXCEPTION '没有访问客户群发的权限' USING ERRCODE = '42501';
  END IF;

  -- 鉴权：task 必须属于当前商户
  IF NOT EXISTS (
    SELECT 1 FROM public.merchant_wecom_mass_tasks
    WHERE id = p_task_id AND root_manager_id = v_root
  ) THEN
    RAISE EXCEPTION '任务不存在或无权查看' USING ERRCODE = '42501';
  END IF;

  SELECT count(*) INTO v_total
  FROM public.merchant_wecom_mass_results r
  WHERE r.task_id = p_task_id
    AND (p_status IS NULL OR r.send_status = p_status);

  SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row.created_at DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT r.userid, r.external_userid, r.send_status, r.fail_reason, r.synced_at, r.created_at
    FROM public.merchant_wecom_mass_results r
    WHERE r.task_id = p_task_id
      AND (p_status IS NULL OR r.send_status = p_status)
    ORDER BY r.created_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_page_size, 50), 1), 200)
    OFFSET (GREATEST(COALESCE(p_page, 1), 1) - 1) * LEAST(GREATEST(COALESCE(p_page_size, 50), 1), 200)
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_pro_mass_results(uuid, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_pro_mass_results(uuid, text, int, int) TO authenticated;


-- ═════════════════════════ Task 14: 客户群 ═════════════════════════

CREATE TABLE IF NOT EXISTS public.merchant_wecom_chat_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  chat_id text NOT NULL,
  name text,
  owner_userid text,
  member_count int NOT NULL DEFAULT 0,
  notice text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_wecom_chat_group UNIQUE (root_manager_id, chat_id)
);

CREATE TABLE IF NOT EXISTS public.merchant_wecom_chat_group_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  root_manager_id uuid NOT NULL REFERENCES public.managers(id) ON DELETE CASCADE,
  chat_id text NOT NULL,
  -- 企微成员 userid（内部员工）或 external_userid（外部联系人）
  member_id text NOT NULL,
  -- member=企业内员工；external=外部联系人
  member_type text NOT NULL DEFAULT 'member' CHECK (member_type IN ('member','external')),
  name text,
  unionid text,
  joined_at timestamptz,
  CONSTRAINT uq_wecom_chat_group_member UNIQUE (root_manager_id, chat_id, member_id)
);

CREATE INDEX IF NOT EXISTS idx_wecom_chat_groups_root
  ON public.merchant_wecom_chat_groups (root_manager_id, name);
CREATE INDEX IF NOT EXISTS idx_wecom_chat_group_members_chat
  ON public.merchant_wecom_chat_group_members (root_manager_id, chat_id);

ALTER TABLE public.merchant_wecom_chat_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.merchant_wecom_chat_group_members ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.merchant_wecom_chat_groups FROM anon, authenticated;
REVOKE ALL ON public.merchant_wecom_chat_group_members FROM anon, authenticated;

-- ── 客户群列表（老板/管理员全量；员工只看自己在的群）──
CREATE OR REPLACE FUNCTION public.list_wecom_pro_chat_groups(
  p_keyword text DEFAULT NULL,
  p_owner_userid text DEFAULT NULL,
  p_page int DEFAULT 1,
  p_page_size int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_keyword text;
  v_is_admin boolean;
  v_my_userid text;
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
  IF NOT public.has_enterprise_permission('wecom_pro_groups', v_uid) THEN
    RAISE EXCEPTION '没有访问客户群的权限' USING ERRCODE = '42501';
  END IF;

  v_keyword := NULLIF(btrim(COALESCE(p_keyword, '')), '');
  v_is_admin := public.is_enterprise_admin(v_uid);

  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
    v_my_userid := NULLIF(btrim(COALESCE(v_my_userid, '')), '');
    IF v_my_userid IS NULL THEN
      RETURN jsonb_build_object('items', '[]'::jsonb, 'total', 0);
    END IF;
  END IF;

  SELECT count(*) INTO v_total
  FROM public.merchant_wecom_chat_groups g
  WHERE g.root_manager_id = v_root
    AND (v_keyword IS NULL OR g.name ILIKE '%' || v_keyword || '%')
    AND (p_owner_userid IS NULL OR g.owner_userid = p_owner_userid)
    AND (
      v_is_admin
      OR EXISTS (
        SELECT 1 FROM public.merchant_wecom_chat_group_members m
        WHERE m.root_manager_id = v_root AND m.chat_id = g.chat_id AND m.member_id = v_my_userid
      )
    );

  SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY row.updated_at DESC NULLS LAST, row.name), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT g.id, g.chat_id, g.name, g.owner_userid, g.member_count, g.notice,
           g.created_at, g.updated_at,
           COALESCE((SELECT p.nickname FROM public.profiles p WHERE p.wecom_userid = g.owner_userid AND COALESCE(p.parent_manager_id, p.id) = v_root LIMIT 1), '') AS owner_name
    FROM public.merchant_wecom_chat_groups g
    WHERE g.root_manager_id = v_root
      AND (v_keyword IS NULL OR g.name ILIKE '%' || v_keyword || '%')
      AND (p_owner_userid IS NULL OR g.owner_userid = p_owner_userid)
      AND (
        v_is_admin
        OR EXISTS (
          SELECT 1 FROM public.merchant_wecom_chat_group_members m
          WHERE m.root_manager_id = v_root AND m.chat_id = g.chat_id AND m.member_id = v_my_userid
        )
      )
    ORDER BY g.updated_at DESC NULLS LAST, g.name
    LIMIT LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100)
    OFFSET (GREATEST(COALESCE(p_page, 1), 1) - 1) * LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100)
  ) row;

  RETURN jsonb_build_object('items', v_items, 'total', v_total);
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_pro_chat_groups(text, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_pro_chat_groups(text, text, int, int) TO authenticated;

-- ── 客户群详情（群信息 + 成员列表）──
CREATE OR REPLACE FUNCTION public.get_wecom_pro_chat_group_detail(p_chat_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_is_admin boolean;
  v_my_userid text;
  v_group public.merchant_wecom_chat_groups%ROWTYPE;
  v_members jsonb;
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
  IF NOT public.has_enterprise_permission('wecom_pro_groups', v_uid) THEN
    RAISE EXCEPTION '没有访问客户群的权限' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_group
  FROM public.merchant_wecom_chat_groups
  WHERE root_manager_id = v_root AND chat_id = btrim(COALESCE(p_chat_id, ''));
  IF v_group.id IS NULL THEN
    RAISE EXCEPTION '群不存在或无权查看' USING ERRCODE = '42501';
  END IF;

  -- 员工只能看自己在的群
  v_is_admin := public.is_enterprise_admin(v_uid);
  IF NOT v_is_admin THEN
    SELECT wecom_userid INTO v_my_userid FROM public.profiles WHERE id = v_uid;
    v_my_userid := NULLIF(btrim(COALESCE(v_my_userid, '')), '');
    IF v_my_userid IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.merchant_wecom_chat_group_members m
      WHERE m.root_manager_id = v_root AND m.chat_id = v_group.chat_id AND m.member_id = v_my_userid
    ) THEN
      RAISE EXCEPTION '群不存在或无权查看' USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'memberId', m.member_id,
    'memberType', m.member_type,
    'name', m.name,
    'unionid', m.unionid,
    'joinedAt', m.joined_at,
    -- 头像：外部成员拉 merchant_wecom_contacts；企业成员拉 profiles
    'avatarUrl', COALESCE(
      CASE WHEN m.member_type = 'external' THEN
        (SELECT c.avatar_url FROM public.merchant_wecom_contacts c
          WHERE c.root_manager_id = v_root AND c.external_userid = m.member_id LIMIT 1)
      END,
      CASE WHEN m.member_type = 'member' THEN
        (SELECT p.avatar_url FROM public.profiles p
          WHERE p.wecom_userid = m.member_id
            AND COALESCE(p.parent_manager_id, p.id) = v_root LIMIT 1)
      END,
      ''
    ),
    -- 外部成员关联客户画像（名称优先用客户库的）
    'contactName', CASE WHEN m.member_type = 'external' THEN
      COALESCE((SELECT c.name FROM public.merchant_wecom_contacts c
        WHERE c.root_manager_id = v_root AND c.external_userid = m.member_id LIMIT 1), m.name)
    ELSE '' END
  ) ORDER BY (m.member_type = 'external'), m.name NULLS LAST), '[]'::jsonb) INTO v_members
  FROM public.merchant_wecom_chat_group_members m
  WHERE m.root_manager_id = v_root AND m.chat_id = v_group.chat_id;

  RETURN jsonb_build_object(
    'id', v_group.id,
    'chatId', v_group.chat_id,
    'name', v_group.name,
    'ownerUserid', v_group.owner_userid,
    'memberCount', v_group.member_count,
    'notice', v_group.notice,
    'createdAt', v_group.created_at,
    'updatedAt', v_group.updated_at,
    'members', v_members
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_wecom_pro_chat_group_detail(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wecom_pro_chat_group_detail(text) TO authenticated;


