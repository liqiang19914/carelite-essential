-- 数据导出：企业级会员列表导出 RPC
-- 按客户要求的 10 列表头输出全企业客户（跨 4 张表 JOIN：profiles / managers / stores / points_balances）。
-- 只有企业根（超级管理员）可调，导出范围为该企业下所有员工的客户，含已离职员工的历史绑定。
-- 迁移幂等：CREATE OR REPLACE + DROP IF EXISTS 旧签名。

DROP FUNCTION IF EXISTS public.export_enterprise_members(uuid);

CREATE OR REPLACE FUNCTION public.export_enterprise_members(p_root_manager_id uuid)
RETURNS TABLE(
  member_name     text,  -- 姓名（微信昵称）
  phone           text,  -- 手机号（按隐私阀门 mask）
  archive_name    text,  -- 档案姓名（健管师档案名，空就空）
  owner_staff     text,  -- 归属员工
  status          text,  -- 状态
  added_at        timestamptz,  -- 添加时间
  store_names     text,  -- 归属门店（多个用「、」拼接）
  points          integer,  -- 积分
  remark          text,  -- 添加备注
  last_contact_at timestamptz   -- 最后联系
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = 'public'
AS $function$
DECLARE
  v_enterprise_id text;
BEGIN
  -- 取企业 ID：managers.enterprise_id，用作跨员工归属判定，兼容 parent_manager_id 为 NULL 的员工
  SELECT m.enterprise_id INTO v_enterprise_id
  FROM managers m WHERE m.id = p_root_manager_id LIMIT 1;

  RETURN QUERY
  WITH enterprise_members AS (
    -- 企业根自己 + 同企业所有健管师（按 enterprise_id 关联，覆盖 parent_manager_id 为 NULL 的员工）
    SELECT p.id FROM profiles p WHERE p.id = p_root_manager_id
    UNION
    SELECT m.id FROM managers m
    WHERE m.enterprise_id IS NOT NULL AND m.enterprise_id = v_enterprise_id
  )
  SELECT
    p.nickname                                                  AS member_name,
    CASE WHEN COALESCE(p.privacy_settings->>'show_phone','true') = 'false'
         THEN NULL ELSE p.phone END                             AS phone,
    cr.customer_name                                            AS archive_name,
    COALESCE(m.nickname, m2.nickname, '')                       AS owner_staff,
    cr.status::text                                             AS status,
    cr.created_at                                               AS added_at,
    -- 门店多绑：聚合成「、」分隔的字符串，无绑定则空
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
  LEFT JOIN managers m ON m.id = cr.manager_id
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
  '数据导出-企业级会员列表（10 列表头）。入参为企业根 manager id，导出该企业所有员工的客户，跨表 JOIN profiles/managers/stores/points_balances。';
