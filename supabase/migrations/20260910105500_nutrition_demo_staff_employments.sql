-- 让膳衡营养演示团队兼容新版企业就业关系；仅处理固定演示企业的五位禁用登录员工。
ALTER TABLE public.enterprise_employments DISABLE TRIGGER trg_enforce_employment_seat_limit;

DO $demo$
DECLARE
  v_root CONSTANT uuid := 'c6cc187c-3b13-40fc-befb-aa70594ebe3c';
  v_enterprise CONSTANT uuid := 'a97f266d-383a-4cc4-ab1c-5d8b91264a54';
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.enterprises
    WHERE id = v_enterprise AND owner_profile_id = v_root
  ) THEN
    RAISE EXCEPTION '膳衡演示企业身份校验失败，已停止写入';
  END IF;

  WITH added AS (
    INSERT INTO public.enterprise_employments (
      auth_user_id, enterprise_id, enterprise_role_id, supervisor_auth_user_id,
      sub_role, permissions, status, is_primary
    )
    SELECT
      m.id, v_enterprise, r.id, v_root,
      'health_manager', '{}'::jsonb, 'active', true
    FROM public.managers m
    JOIN public.enterprise_roles r
      ON r.enterprise_id = v_enterprise AND r.code = 'health_manager'
    WHERE m.enterprise_id = v_enterprise
      AND m.system_default_key IN ('chronic','gut','weight','sleep','fitness')
      AND NOT EXISTS (
        SELECT 1 FROM public.enterprise_employments ee
        WHERE ee.auth_user_id = m.id
          AND ee.enterprise_id = v_enterprise
          AND ee.status IN ('active','disabled','pending')
      )
    RETURNING id, auth_user_id, enterprise_role_id
  )
  UPDATE public.profiles p SET
    enterprise_id = v_enterprise,
    enterprise_role_id = a.enterprise_role_id,
    primary_employment_id = a.id,
    parent_manager_id = v_root,
    sub_role = 'health_manager',
    role = 'manager',
    updated_at = now()
  FROM added a
  WHERE p.id = a.auth_user_id;
END
$demo$;

ALTER TABLE public.enterprise_employments ENABLE TRIGGER trg_enforce_employment_seat_limit;
