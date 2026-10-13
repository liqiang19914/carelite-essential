-- 数据导出权限加固：确保只有企业超级管理员（企业根）才能导出和下载数据。
--
-- 修复 3 个越权漏洞：
-- 1. export_enterprise_members RPC 原先 GRANT TO authenticated 且无企业根校验，
--    普通员工传自己 user.id 也能导出整个企业的客户（enterprise_members CTE 会按
--    enterprise_id 把同企业所有 managers 的客户都纳入）。
-- 2. export_tasks RLS 原先只校验 root_manager_id = auth.uid()，普通员工能创建任务。
-- 3. Edge Function 原先只校验 task.root_manager_id = JWT uid，普通员工能触发处理。
--
-- 加固策略：在数据库层（RPC + RLS）双重校验调用者是企业根。企业根判定用
-- get_enterprise_root_manager_id(uid) 返回值是否等于入参 uid。
-- 迁移幂等：DROP IF EXISTS + CREATE OR REPLACE + DO 块 guarded。

-- ============================================================================
-- 1. RPC 加企业根校验
-- ============================================================================
DROP FUNCTION IF EXISTS public.export_enterprise_members(uuid);

CREATE OR REPLACE FUNCTION public.export_enterprise_members(p_root_manager_id uuid)
RETURNS TABLE(
  member_name     text,
  phone           text,
  archive_name    text,
  owner_staff     text,
  status          text,
  added_at        timestamptz,
  store_names     text,
  points          integer,
  remark          text,
  last_contact_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = 'public'
AS $function$
DECLARE
  v_enterprise_id uuid;
  v_root_id uuid;
BEGIN
  -- 权限校验：调用者必须是企业超级管理员（企业根）。
  -- get_enterprise_root_manager_id 反查企业根 owner_profile_id，若返回值不等于
  -- 入参 p_root_manager_id，说明调用者不是企业根，直接拒绝。
  v_root_id := public.get_enterprise_root_manager_id(p_root_manager_id);
  IF v_root_id IS DISTINCT FROM p_root_manager_id THEN
    RAISE EXCEPTION '只有企业超级管理员才能导出企业数据';
  END IF;

  SELECT m.enterprise_id INTO v_enterprise_id
  FROM managers m WHERE m.id = p_root_manager_id LIMIT 1;

  RETURN QUERY
  WITH enterprise_members AS (
    SELECT p.id FROM profiles p WHERE p.id = p_root_manager_id
    UNION
    SELECT m.id FROM managers m
    WHERE m.enterprise_id IS NOT NULL AND m.enterprise_id = v_enterprise_id
  )
  SELECT
    p.nickname::text                                            AS member_name,
    CASE WHEN COALESCE(p.privacy_settings->>'show_phone','true') = 'false'
         THEN NULL ELSE p.phone::text END                       AS phone,
    COALESCE(
      (SELECT phr.name FROM health_records phr
        WHERE phr.user_id = cr.client_id
          AND phr.relationship IN ('本人','self')
          AND btrim(COALESCE(phr.name,'')) <> ''
          AND phr.name NOT IN ('未命名客户','微信用户')
          AND phr.name NOT LIKE '用户%'
        ORDER BY phr.is_default DESC NULLS LAST, phr.updated_at DESC, phr.created_at DESC
        LIMIT 1),
      (SELECT phr.name FROM health_records phr
        JOIN profiles hp ON hp.id = phr.user_id
        WHERE btrim(COALESCE(p.phone,'')) <> ''
          AND hp.phone = p.phone AND hp.id <> cr.client_id
          AND phr.relationship IN ('本人','self')
          AND btrim(COALESCE(phr.name,'')) <> ''
          AND phr.name NOT IN ('未命名客户','微信用户')
          AND phr.name NOT LIKE '用户%'
        ORDER BY phr.is_default DESC NULLS LAST, phr.updated_at DESC, phr.created_at DESC
        LIMIT 1)
    )::text                                                      AS archive_name,
    COALESCE(m2.nickname, '')::text                              AS owner_staff,
    cr.status::text                                              AS status,
    cr.created_at                                                AS added_at,
    COALESCE((
      SELECT string_agg(s.name, '、')
      FROM user_store_bindings usb
      JOIN stores s ON s.id = usb.store_id
      WHERE usb.user_id = cr.client_id AND usb.status = 'active'
    ), '')                                                       AS store_names,
    COALESCE(pb.balance, 0)                                     AS points,
    COALESCE(cr.notes, '')                                      AS remark,
    cr.last_contact_at                                           AS last_contact_at
  FROM client_relations cr
  JOIN profiles p ON p.id = cr.client_id
  LEFT JOIN profiles m2 ON m2.id = cr.manager_id
  LEFT JOIN points_balances pb ON pb.user_id = cr.client_id
  WHERE cr.status != 'deleted'
    AND cr.manager_id IN (SELECT id FROM enterprise_members)
  ORDER BY cr.created_at DESC;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.export_enterprise_members(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.export_enterprise_members(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.export_enterprise_members(uuid) TO authenticated;

COMMENT ON FUNCTION public.export_enterprise_members(uuid) IS
  '数据导出-企业级会员列表（10 列表头）。入参为企业根 manager id，导出该企业所有员工的客户，跨表 JOIN profiles/managers/stores/points_balances。权限：只有企业超级管理员可调（RPC 内部用 get_enterprise_root_manager_id 校验）。';

-- ============================================================================
-- 2. export_tasks RLS 加强：只有企业根才能 INSERT/SELECT/UPDATE
-- ============================================================================
-- 原 RLS 只校验 root_manager_id = auth.uid()，普通员工能创建任务。
-- 加强为：root_manager_id = auth.uid() AND auth.uid() 是企业根。
-- get_enterprise_root_manager_id 是 STABLE SECURITY DEFINER，RLS policy 内调用安全
-- （不依赖 export_tasks 表，无递归风险）。

DROP POLICY IF EXISTS export_tasks_select_own ON public.export_tasks;
CREATE POLICY export_tasks_select_own ON public.export_tasks
  FOR SELECT TO authenticated
  USING (root_manager_id = auth.uid()
         AND public.get_enterprise_root_manager_id(auth.uid()) = auth.uid());

DROP POLICY IF EXISTS export_tasks_insert_own ON public.export_tasks;
CREATE POLICY export_tasks_insert_own ON public.export_tasks
  FOR INSERT TO authenticated
  WITH CHECK (root_manager_id = auth.uid()
              AND public.get_enterprise_root_manager_id(auth.uid()) = auth.uid());

DROP POLICY IF EXISTS export_tasks_update_own ON public.export_tasks;
CREATE POLICY export_tasks_update_own ON public.export_tasks
  FOR UPDATE TO authenticated
  USING (root_manager_id = auth.uid()
         AND public.get_enterprise_root_manager_id(auth.uid()) = auth.uid())
  WITH CHECK (root_manager_id = auth.uid()
              AND public.get_enterprise_root_manager_id(auth.uid()) = auth.uid());

COMMENT ON TABLE public.export_tasks IS
  '后台导出任务记录。RLS 限定只有企业超级管理员可 INSERT/SELECT/UPDATE（root_manager_id = auth.uid() 且 auth.uid() 是企业根）。service role 绕过 RLS（Edge Function 用）。';
