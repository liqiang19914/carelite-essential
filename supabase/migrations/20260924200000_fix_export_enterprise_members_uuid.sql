-- 修复 export_enterprise_members RPC：
-- 1. v_enterprise_id 之前声明为 text，但 managers.enterprise_id 列是 uuid，
--    导致 `m.enterprise_id = v_enterprise_id` 触发 `operator does not exist: uuid = text`。改为 uuid。
-- 2. archive_name 之前取 cr.customer_name（商户自定备注名，多数为空），但客户管理页"档案姓名"列实际
--    取的是客户本人小程序健康档案里的姓名（health_records 表 lookup），两套口径不一致导致导出空。
--    这里对齐客户管理页：本人账号 health_records 里 relationship='本人'/'self' 的 name 优先，
--    同手机号其他账号兜底；过滤掉 '未命名客户'/'微信用户'/'用户%' 占位值。
-- 迁移幂等：DROP IF EXISTS + CREATE OR REPLACE。

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
BEGIN
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
    -- 档案姓名：与客户管理页 profile_name 字段口径一致——health_records 里
    -- relationship='本人'/'self' 的 name，本人账号优先、同手机号账号兜底；
    -- 过滤掉 '未命名客户'/'微信用户'/'用户%' 等占位名
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
  '数据导出-企业级会员列表（10 列表头）。入参为企业根 manager id，导出该企业所有员工的客户，跨表 JOIN profiles/managers/stores/points_balances。v_enterprise_id 必须为 uuid，匹配 managers.enterprise_id 列类型。';
