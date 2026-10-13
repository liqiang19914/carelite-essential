-- 修复 list_wecom_pro_staff 成员口径：parent_manager_id 为 NULL 但在本企业有
-- 就业行（enterprise_employments ← enterprises.owner_profile_id）的已绑企微员工
-- 此前不会出现在群发对象/客户筛选员工列表中（典型：松哥）。
CREATE OR REPLACE FUNCTION public.list_wecom_pro_staff()
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

  RETURN COALESCE(
    (
      SELECT jsonb_agg(jsonb_build_object(
        'id', p.id,
        'nickname', p.nickname,
        'wecomUserid', p.wecom_userid
      ) ORDER BY p.nickname)
      FROM public.profiles p
      WHERE p.role = 'manager'
        AND COALESCE(p.is_disabled, false) = false
        AND COALESCE(btrim(COALESCE(p.wecom_userid, '')), '') <> ''
        AND (
          p.id = v_root
          OR p.parent_manager_id = v_root
          OR EXISTS (
            SELECT 1
            FROM public.enterprise_employments ee
            JOIN public.enterprises e ON e.id = ee.enterprise_id
            WHERE ee.auth_user_id = p.id
              AND e.owner_profile_id = v_root
              AND ee.status IN ('active', 'disabled', 'pending')
          )
        )
    ),
    '[]'::jsonb
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.list_wecom_pro_staff() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wecom_pro_staff() TO authenticated;
