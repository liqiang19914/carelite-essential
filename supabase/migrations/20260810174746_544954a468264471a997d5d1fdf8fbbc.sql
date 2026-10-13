-- 企业老板 / 企业管理员能看全企业员工名下客户的称重记录。
-- 只放开 body_compositions 这一张：本次需求是「称重数据」，
-- health_records 里还有病史/用药史，没有必要跟着一起放开。
--
-- 隐私闸门与员工本人看自己客户时完全一致：档案授权 active 且未过期
-- + 客户关系 active + 客户没关掉体征共享。企业身份多出来的只是
-- 「授权可以挂在同企业的另一位员工名下」这一点。
CREATE OR REPLACE FUNCTION public.can_current_enterprise_admin_view_body_composition(p_record_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.record_authorizations ra
    JOIN public.health_records hr ON hr.id = ra.record_id
    JOIN public.client_relations cr
      ON cr.manager_id = ra.manager_id AND cr.client_id = hr.user_id
    WHERE ra.record_id = p_record_id
      AND ra.is_active = true
      AND (ra.expires_at IS NULL OR ra.expires_at > now())
      AND cr.status = 'active'
      AND public.can_manager_view_client_category(hr.user_id, 'share_vitals')
      -- 这个函数自己会校验调用者是 manager、未被停用、且确实是企业主或 sub_role=admin
      AND public.is_enterprise_member_for_admin(ra.manager_id, (SELECT auth.uid()))
  );
$function$;

REVOKE ALL ON FUNCTION public.can_current_enterprise_admin_view_body_composition(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_current_enterprise_admin_view_body_composition(uuid) TO authenticated;

DROP POLICY IF EXISTS "Enterprise admin views member body compositions" ON public.body_compositions;
CREATE POLICY "Enterprise admin views member body compositions"
  ON public.body_compositions
  FOR SELECT
  TO authenticated
  USING (public.can_current_enterprise_admin_view_body_composition(record_id));

COMMENT ON FUNCTION public.can_current_enterprise_admin_view_body_composition(uuid) IS
  '企业主 / 企业管理员能否看这条称重记录。单体商户调用时等价于只看自己，不产生额外可见范围。';