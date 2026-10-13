BEGIN;
DO $function$
DECLARE
  v_test uuid := gen_random_uuid();
  v_ent uuid;
BEGIN
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token,
    email_change_token_new, email_change, banned_until
  ) VALUES (
    '00000000-0000-0000-0000-000000000000', v_test,
    'authenticated', 'authenticated',
    'probe-test2@kaitong.local',
    crypt(gen_random_uuid()::text, gen_salt('bf')),
    NOW(),
    '{"provider": "system", "providers": ["system"]}'::jsonb,
    '{"nickname": "探针2"}'::jsonb,
    NOW(), NOW(), '', '', '', '',
    'infinity'::timestamptz
  );

  UPDATE public.profiles
     SET nickname = '平台运营中心', role = 'manager', sub_role = '', is_verified = true, is_disabled = false
   WHERE id = v_test;
  RAISE NOTICE 'profile update ok';

  INSERT INTO public.managers (
    id, business_name, certification_status, membership_level,
    company_name, is_platform_root, created_at, updated_at
  ) VALUES (
    v_test, '平台运营中心', 'approved', 'free', '平台运营中心', true, NOW(), NOW()
  );
  RAISE NOTICE 'manager insert ok';

  INSERT INTO public.enterprises (name, owner_profile_id, created_by)
  VALUES ('平台运营中心', v_test, v_test)
  RETURNING id INTO v_ent;
  RAISE NOTICE 'enterprise insert ok %', v_ent;
END;
$function$;
ROLLBACK;