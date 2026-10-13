-- 企微助手 Pro（SCRM 高级版）框架：
-- 1) merchant_module_grants 模块白名单新增 wecom_assistant_pro（含 CHECK 约束 + 三个 RPC 白名单）
-- 2) Pro 菜单权限码入库（一级 wecom_pro + 7 个子菜单）
-- 3) 存量拥有 wecom_assistant 的角色回填 Pro 权限码
-- 4) 卓越耀美灰度 seed（授予 + 开启）

-- ───────────────────────────── 1. 模块键 CHECK 约束扩展 ─────────────────────────────

ALTER TABLE public.merchant_module_grants DROP CONSTRAINT IF EXISTS mmg_module_key_check;

ALTER TABLE public.merchant_module_grants ADD CONSTRAINT mmg_module_key_check
CHECK (module_key = ANY (ARRAY[
  'shop_order_lifecycle', 'points_exchange', 'stores',
  'view_conversations', 'view_health_insights', 'view_health_records',
  'native_login', 'marketing_center', 'wecom_assistant_pro'
]::text[]));

-- ───────────────────────────── 2. 三个模块授权 RPC 白名单扩展 ─────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_set_merchant_module_grant(p_manager_id uuid, p_module_key text, p_granted boolean, p_notes text DEFAULT NULL::text)
RETURNS merchant_module_grants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.merchant_module_grants;
BEGIN
  IF v_uid IS NULL OR NOT public.is_admin(v_uid) THEN
    RAISE EXCEPTION '只有平台管理员可以调整商户模块授权' USING ERRCODE = '42501';
  END IF;
  IF p_module_key NOT IN ('shop_order_lifecycle', 'points_exchange', 'view_health_records', 'view_health_insights', 'view_conversations', 'stores', 'native_login', 'marketing_center', 'wecom_assistant_pro') THEN
    RAISE EXCEPTION '未知的模块' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.managers WHERE id = p_manager_id) THEN
    RAISE EXCEPTION '找不到该商户' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.merchant_module_grants (
    manager_id, module_key, grant_status, is_enabled, granted_by, notes
  ) VALUES (
    p_manager_id, p_module_key,
    CASE WHEN COALESCE(p_granted, false) THEN 'granted' ELSE 'revoked' END,
    false, v_uid, p_notes
  )
  ON CONFLICT (manager_id, module_key) DO UPDATE
  SET grant_status = CASE WHEN COALESCE(p_granted, false) THEN 'granted' ELSE 'revoked' END,
      is_enabled   = CASE WHEN COALESCE(p_granted, false)
                          THEN public.merchant_module_grants.is_enabled
                          ELSE false END,
      granted_by   = v_uid,
      granted_at   = now(),
      notes        = COALESCE(p_notes, public.merchant_module_grants.notes),
      updated_at   = now()
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_my_merchant_module_state(p_module_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root      uuid;
  v_granted   boolean := false;
  v_enabled   boolean := false;
  v_permitted boolean := true;
  v_is_data   boolean;
BEGIN
  IF p_module_key IS NULL
     OR p_module_key NOT IN ('points_exchange', 'stores', 'shop_order_lifecycle', 'view_health_records', 'view_health_insights', 'view_conversations', 'marketing_center', 'wecom_assistant_pro') THEN
    RAISE EXCEPTION '未知的商城模块' USING ERRCODE = '22023';
  END IF;

  v_root := public._my_root_manager_id();
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  SELECT (g.grant_status = 'granted'), COALESCE(g.is_enabled, false)
  INTO v_granted, v_enabled
  FROM public.merchant_module_grants g
  WHERE g.manager_id = v_root
    AND g.module_key = p_module_key;

  v_granted := COALESCE(v_granted, false);
  v_enabled := COALESCE(v_enabled, false);
  v_is_data := p_module_key IN ('view_health_records', 'view_health_insights', 'view_conversations');

  IF v_is_data THEN
    v_permitted := public.has_enterprise_permission(
      CASE p_module_key
        WHEN 'view_health_records'  THEN 'view_health_records'
        WHEN 'view_health_insights' THEN 'health_insights'
        ELSE 'conversations'
      END,
      auth.uid()
    );
  END IF;

  RETURN jsonb_build_object(
    'granted', v_granted,
    'enabled', v_enabled,
    'permitted', COALESCE(v_permitted, false),
    'open', CASE
              WHEN v_is_data THEN v_granted AND COALESCE(v_permitted, false)
              ELSE v_granted AND v_enabled
            END
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_my_merchant_module_enabled(p_module_key text, p_enabled boolean)
RETURNS merchant_module_grants
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_root uuid := public._my_root_manager_id();
  v_row  public.merchant_module_grants;
  v_parent uuid;
  v_sub_role text;
  v_disabled boolean;
BEGIN
  IF v_root IS NULL THEN
    RAISE EXCEPTION '只有商户账号可以设置商城模块' USING ERRCODE = '42501';
  END IF;
  IF p_module_key IN ('view_health_records', 'view_health_insights', 'view_conversations') THEN
    RAISE EXCEPTION '客户数据的查看权限已改为按角色授予，请到「企业中心 → 角色权限」里为对应角色勾选' USING ERRCODE = '22023';
  END IF;
  IF p_module_key NOT IN ('shop_order_lifecycle', 'points_exchange', 'stores', 'marketing_center', 'wecom_assistant_pro') THEN
    RAISE EXCEPTION '未知的模块' USING ERRCODE = '22023';
  END IF;

  SELECT parent_manager_id, sub_role, COALESCE(is_disabled, false)
    INTO v_parent, v_sub_role, v_disabled
    FROM public.profiles
   WHERE id = auth.uid();
  IF v_disabled OR NOT (v_parent IS NULL OR v_sub_role = 'admin') THEN
    RAISE EXCEPTION '只有企业主或企业管理员可以设置商城模块' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row
  FROM public.merchant_module_grants
  WHERE manager_id = v_root AND module_key = p_module_key
  FOR UPDATE;

  IF v_row.id IS NULL OR v_row.grant_status <> 'granted' THEN
    RAISE EXCEPTION '平台尚未为你开放该模块，请联系平台运营' USING ERRCODE = '42501';
  END IF;

  UPDATE public.merchant_module_grants
  SET is_enabled = COALESCE(p_enabled, false), updated_at = now()
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

-- ───────────────────────────── 3. Pro 菜单权限码 ─────────────────────────────

INSERT INTO public.permission_definitions (code, name, node_level, parent_code, permission_kind, sort_order, description)
VALUES
  ('wecom_pro',         '企微助手 Pro', 1, NULL,              'menu', 106, 'SCRM 高级版：客户库、标签、欢迎语、群发、客户群、会话存档'),
  ('wecom_pro_customers','客户库',      2, 'wecom_pro',       'menu', 10,  '企微客户列表与客户画像，打通系统客户与健康档案'),
  ('wecom_pro_tags',    '标签管理',     2, 'wecom_pro',       'menu', 20,  '企微企业标签同步、管理与客户打标'),
  ('wecom_pro_welcome', '新客欢迎语',   2, 'wecom_pro',       'menu', 30,  '加好友自动欢迎语模板与发送记录'),
  ('wecom_pro_massmsg', '客户群发',     2, 'wecom_pro',       'menu', 40,  '按标签/员工创建群发任务并追踪员工发送回执'),
  ('wecom_pro_groups',  '客户群',       2, 'wecom_pro',       'menu', 50,  '客户群同步与群成员查看'),
  ('wecom_pro_archive', '会话存档',     2, 'wecom_pro',       'menu', 60,  '员工与客户单聊/客户群聊天记录存档查看'),
  ('wecom_pro_audit',   '敏感审计',     2, 'wecom_pro',       'menu', 70,  '会话存档敏感词命中审计')
ON CONFLICT (code) DO NOTHING;

-- ───────────────────────────── 4. 存量角色回填（已有旧版企微助手的角色） ─────────────────────────────

INSERT INTO public.enterprise_role_permissions (role_id, permission_code)
SELECT rp.role_id, c.code
FROM public.enterprise_role_permissions rp
CROSS JOIN (
  VALUES ('wecom_pro'), ('wecom_pro_customers'), ('wecom_pro_tags'),
         ('wecom_pro_welcome'), ('wecom_pro_massmsg'), ('wecom_pro_groups'),
         ('wecom_pro_archive'), ('wecom_pro_audit')
) AS c(code)
WHERE rp.permission_code = 'wecom_assistant'
ON CONFLICT DO NOTHING;

-- ───────────────────────────── 5. 灰度 seed：卓越耀美授予并开启 ─────────────────────────────

INSERT INTO public.merchant_module_grants (manager_id, module_key, grant_status, is_enabled, notes)
VALUES (
  '5424dfb1-f528-436c-bd75-2028e3c2e286',
  'wecom_assistant_pro',
  'granted',
  true,
  '企微助手 Pro 灰度首发商户'
)
ON CONFLICT (manager_id, module_key) DO UPDATE
SET grant_status = 'granted',
    is_enabled   = true,
    notes        = COALESCE(public.merchant_module_grants.notes, EXCLUDED.notes),
    updated_at   = now();
