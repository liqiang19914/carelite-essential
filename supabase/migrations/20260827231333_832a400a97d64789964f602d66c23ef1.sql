-- 修复 restore/purge：FOR UPDATE 不能作用于外连接可空侧，改为子查询方式的企业归属校验
CREATE OR REPLACE FUNCTION public.restore_deleted_client(p_relation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_row record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RAISE EXCEPTION '仅企业超级管理员可操作回收站' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  SELECT cr.id, cr.client_id
  INTO v_row
  FROM public.client_relations cr
  WHERE cr.id = p_relation_id
    AND cr.status = 'deleted'
    AND (
      cr.root_manager_id = v_root
      OR (cr.root_manager_id IS NULL AND cr.manager_id IN (
        SELECT v_root AS mid
        UNION
        SELECT mp.id FROM public.profiles mp
        WHERE mp.parent_manager_id = v_root AND mp.role = 'manager'
      ))
    )
  FOR UPDATE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION '未找到该回收站记录，可能已恢复或已删除' USING ERRCODE = 'P0002';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.client_relations cr2
    WHERE cr2.client_id = v_row.client_id
      AND cr2.status = 'active'
      AND (
        cr2.root_manager_id = v_root
        OR (cr2.root_manager_id IS NULL AND cr2.manager_id IN (
          SELECT v_root AS mid
          UNION
          SELECT mp2.id FROM public.profiles mp2
          WHERE mp2.parent_manager_id = v_root AND mp2.role = 'manager'
        ))
      )
  ) THEN
    RAISE EXCEPTION '该客户已在客户列表中，无需恢复' USING ERRCODE = '23505';
  END IF;

  BEGIN
    UPDATE public.client_relations
    SET status = 'active', updated_at = now()
    WHERE id = v_row.id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION '该客户已在客户列表中，无需恢复' USING ERRCODE = '23505';
  END;
END;
$function$;

REVOKE ALL ON FUNCTION public.restore_deleted_client(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.restore_deleted_client(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.restore_deleted_client(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.purge_deleted_client(p_relation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_root uuid;
  v_row record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;
  IF NOT public.has_enterprise_permission('enterprise_roles', v_uid) THEN
    RAISE EXCEPTION '仅企业超级管理员可操作回收站' USING ERRCODE = '42501';
  END IF;
  v_root := public.get_enterprise_root_manager_id(v_uid);
  IF v_root IS NULL THEN
    RAISE EXCEPTION '当前账号不是商户账号' USING ERRCODE = '42501';
  END IF;

  SELECT cr.id
  INTO v_row
  FROM public.client_relations cr
  WHERE cr.id = p_relation_id
    AND cr.status = 'deleted'
    AND (
      cr.root_manager_id = v_root
      OR (cr.root_manager_id IS NULL AND cr.manager_id IN (
        SELECT v_root AS mid
        UNION
        SELECT mp.id FROM public.profiles mp
        WHERE mp.parent_manager_id = v_root AND mp.role = 'manager'
      ))
    )
  FOR UPDATE;

  IF v_row IS NULL THEN
    RAISE EXCEPTION '未找到该回收站记录，可能已恢复或已删除' USING ERRCODE = 'P0002';
  END IF;

  DELETE FROM public.client_relations WHERE id = v_row.id;
END;
$function$;

REVOKE ALL ON FUNCTION public.purge_deleted_client(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_deleted_client(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.purge_deleted_client(uuid) TO authenticated;