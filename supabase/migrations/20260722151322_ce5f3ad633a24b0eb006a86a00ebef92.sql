-- ============================================
-- 管理师端「操作日志」→「管理记录」改口径
-- 补齐 operation_logs 表 DDL + 审计快照字段 + get_manager_operation_logs RPC
-- ============================================

-- 1. 基础建表（幂等）：与线上现存结构一致，便于新环境从零可复现
CREATE TABLE IF NOT EXISTS public.operation_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  action TEXT NOT NULL,
  detail TEXT,
  module TEXT NOT NULL,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. 补两个不可变审计快照字段
--    enterprise_root_id：日志归属的企业根 manager id
--      - boss 自己产生：boss.id
--      - 员工产生：员工的 parent_manager_id（= boss.id）
--      - admin / user / 无 profile：NULL
--    actor_name_snapshot：操作发生瞬间冻结的操作人显示名
--    这两个字段由 BEFORE INSERT 触发器基于 user_id 无条件覆盖，防伪造
ALTER TABLE public.operation_logs
  ADD COLUMN IF NOT EXISTS enterprise_root_id UUID,
  ADD COLUMN IF NOT EXISTS actor_name_snapshot TEXT;

-- 3. 索引：保留原有 3 条 + 新增 2 条键集分页复合索引
CREATE INDEX IF NOT EXISTS idx_operation_logs_user_id
  ON public.operation_logs (user_id);

CREATE INDEX IF NOT EXISTS idx_operation_logs_created_at
  ON public.operation_logs (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_operation_logs_module
  ON public.operation_logs (module);

-- 企业主视角：enterprise_root_id 定点 + (created_at, id) 键集分页
CREATE INDEX IF NOT EXISTS idx_operation_logs_enterprise_recent
  ON public.operation_logs (enterprise_root_id, created_at DESC, id DESC)
  WHERE enterprise_root_id IS NOT NULL;

-- 员工视角：user_id 定点 + (created_at, id) 键集分页
CREATE INDEX IF NOT EXISTS idx_operation_logs_user_recent
  ON public.operation_logs (user_id, created_at DESC, id DESC);

-- 4. RLS 与既有 3 条策略幂等（DROP + CREATE，因 PG 的 CREATE POLICY 不支持 IF NOT EXISTS）
ALTER TABLE public.operation_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can view all logs" ON public.operation_logs;
CREATE POLICY "Admins can view all logs"
  ON public.operation_logs
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role = 'admin'
    )
  );

DROP POLICY IF EXISTS "Users can view own logs" ON public.operation_logs;
CREATE POLICY "Users can view own logs"
  ON public.operation_logs
  FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own logs" ON public.operation_logs;
CREATE POLICY "Users can insert own logs"
  ON public.operation_logs
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- 5. 显式表权限：撤销 anon，授予 authenticated 基本操作（RLS 兜底）
REVOKE ALL ON public.operation_logs FROM PUBLIC;
REVOKE ALL ON public.operation_logs FROM anon;
GRANT SELECT, INSERT ON public.operation_logs TO authenticated;

-- 6. BEFORE INSERT 触发器函数：基于 user_id 无条件覆盖两个快照字段
CREATE OR REPLACE FUNCTION public.operation_logs_snapshot_actor()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_role user_role;
  v_parent UUID;
  v_nickname TEXT;
  v_partner_display TEXT;
  v_actor_name TEXT;
  v_enterprise_root UUID := NULL;
BEGIN
  SELECT p.role, p.parent_manager_id, p.nickname
    INTO v_role, v_parent, v_nickname
    FROM public.profiles p
   WHERE p.id = NEW.user_id;

  IF FOUND THEN
    IF v_role = 'manager' THEN
      -- 企业主：parent_manager_id 为 NULL → 企业根 = 自己
      -- 员工：企业根 = parent_manager_id
      v_enterprise_root := COALESCE(v_parent, NEW.user_id);
    END IF;

    v_actor_name := NULLIF(TRIM(COALESCE(v_nickname, '')), '');
  END IF;

  -- 昵称兜底：查 managers.partner_card_display_name
  IF v_actor_name IS NULL THEN
    SELECT NULLIF(TRIM(COALESCE(m.partner_card_display_name, '')), '')
      INTO v_partner_display
      FROM public.managers m
     WHERE m.id = NEW.user_id;
    v_actor_name := v_partner_display;
  END IF;

  -- 无条件覆盖（防客户端伪造）
  NEW.enterprise_root_id := v_enterprise_root;
  NEW.actor_name_snapshot := v_actor_name;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_operation_logs_snapshot_actor ON public.operation_logs;
CREATE TRIGGER trg_operation_logs_snapshot_actor
  BEFORE INSERT ON public.operation_logs
  FOR EACH ROW
  EXECUTE FUNCTION public.operation_logs_snapshot_actor();

-- 7. 一次性历史数据回填
--    只回填 profile.role = 'manager' 的行；admin/user 类日志 enterprise_root_id 保持 NULL
UPDATE public.operation_logs AS ol
   SET enterprise_root_id = COALESCE(p.parent_manager_id, p.id),
       actor_name_snapshot = COALESCE(
         NULLIF(TRIM(COALESCE(p.nickname, '')), ''),
         NULLIF(TRIM(COALESCE(m.partner_card_display_name, '')), '')
       )
  FROM public.profiles p
  LEFT JOIN public.managers m ON m.id = p.id
 WHERE ol.user_id = p.id
   AND p.role = 'manager'
   AND (ol.enterprise_root_id IS NULL OR ol.actor_name_snapshot IS NULL);

-- 8. 管理师端 RPC：get_manager_operation_logs
--    - 拒绝 admin（超管走 /admin/system）
--    - 企业主（parent_manager_id IS NULL）：按 enterprise_root_id = auth.uid()
--    - 员工：按 user_id = auth.uid()
--    - 键集分页：(created_at DESC, id DESC) + before_created_at / before_id 双游标
--    - actor_name 兜底：actor_name_snapshot → profiles.nickname → managers.partner_card_display_name → '未知用户'
--    - 单独返回可见范围内的 modules[]（不受 p_module 和分页影响）
CREATE OR REPLACE FUNCTION public.get_manager_operation_logs(
  p_module TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 50,
  p_before_created_at TIMESTAMPTZ DEFAULT NULL,
  p_before_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_caller RECORD;
  v_is_boss BOOLEAN := FALSE;
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_rows JSONB;
  v_modules JSONB;
  v_has_more BOOLEAN := FALSE;
  v_last_created_at TIMESTAMPTZ;
  v_last_id UUID;
  v_next_cursor JSONB := NULL;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('error', 'not_authenticated');
  END IF;

  SELECT id, role, parent_manager_id, is_disabled
    INTO v_caller
    FROM public.profiles
   WHERE id = v_uid;

  IF v_caller.id IS NULL THEN
    RETURN jsonb_build_object('error', 'profile_not_found');
  END IF;

  IF v_caller.is_disabled THEN
    RETURN jsonb_build_object('error', 'account_disabled');
  END IF;

  IF v_caller.role = 'admin' THEN
    RETURN jsonb_build_object('error', 'admin_should_use_admin_console');
  END IF;

  IF v_caller.role <> 'manager' THEN
    RETURN jsonb_build_object('error', 'manager_only');
  END IF;

  v_is_boss := v_caller.parent_manager_id IS NULL;

  -- 主查询：取当前页 + 记录最后一条位置用于 has_more 探测
  WITH page AS (
    SELECT
      ol.id,
      ol.user_id,
      ol.action,
      ol.detail,
      ol.module,
      ol.created_at,
      COALESCE(
        NULLIF(TRIM(COALESCE(ol.actor_name_snapshot, '')), ''),
        NULLIF(TRIM(COALESCE(p.nickname, '')), ''),
        NULLIF(TRIM(COALESCE(m.partner_card_display_name, '')), ''),
        '未知用户'
      ) AS actor_name
    FROM public.operation_logs ol
    LEFT JOIN public.profiles p ON p.id = ol.user_id
    LEFT JOIN public.managers m ON m.id = ol.user_id
    WHERE
      CASE WHEN v_is_boss THEN ol.enterprise_root_id = v_uid
           ELSE ol.user_id = v_uid END
      AND (p_module IS NULL OR ol.module = p_module)
      AND (
        p_before_created_at IS NULL
        OR ol.created_at < p_before_created_at
        OR (ol.created_at = p_before_created_at AND ol.id < p_before_id)
      )
    ORDER BY ol.created_at DESC, ol.id DESC
    LIMIT v_limit
  )
  SELECT
    COALESCE(jsonb_agg(
      jsonb_build_object(
        'id', page.id,
        'user_id', page.user_id,
        'actor_name', page.actor_name,
        'action', page.action,
        'detail', page.detail,
        'module', page.module,
        'created_at', page.created_at
      ) ORDER BY page.created_at DESC, page.id DESC
    ), '[]'::jsonb),
    (SELECT created_at FROM page ORDER BY created_at ASC, id ASC LIMIT 1),
    (SELECT id FROM page ORDER BY created_at ASC, id ASC LIMIT 1)
  INTO v_rows, v_last_created_at, v_last_id
  FROM page;

  -- has_more 探测：是否存在(created_at, id) 严格小于当前页最后一条的行
  IF v_last_created_at IS NOT NULL THEN
    SELECT EXISTS(
      SELECT 1 FROM public.operation_logs ol
      WHERE
        CASE WHEN v_is_boss THEN ol.enterprise_root_id = v_uid
             ELSE ol.user_id = v_uid END
        AND (p_module IS NULL OR ol.module = p_module)
        AND (
          ol.created_at < v_last_created_at
          OR (ol.created_at = v_last_created_at AND ol.id < v_last_id)
        )
      LIMIT 1
    ) INTO v_has_more;
  END IF;

  IF v_has_more THEN
    v_next_cursor := jsonb_build_object(
      'before_created_at', v_last_created_at,
      'before_id', v_last_id
    );
  END IF;

  -- 可见范围内的模块列表（去重，不受 p_module 和分页影响）
  SELECT COALESCE(jsonb_agg(DISTINCT ol.module ORDER BY ol.module), '[]'::jsonb)
    INTO v_modules
    FROM public.operation_logs ol
   WHERE
     CASE WHEN v_is_boss THEN ol.enterprise_root_id = v_uid
          ELSE ol.user_id = v_uid END
     AND ol.module IS NOT NULL;

  RETURN jsonb_build_object(
    'items', v_rows,
    'modules', v_modules,
    'has_more', v_has_more,
    'next_cursor', v_next_cursor
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_manager_operation_logs(TEXT, INTEGER, TIMESTAMPTZ, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_manager_operation_logs(TEXT, INTEGER, TIMESTAMPTZ, UUID) TO authenticated;