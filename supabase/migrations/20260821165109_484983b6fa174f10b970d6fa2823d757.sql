DO $function$
DECLARE
  v_platform_root uuid;
  v_platform_ent uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.system_settings WHERE key = 'platform_manager_root_id') THEN
    v_platform_root := gen_random_uuid();

    INSERT INTO auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token,
      email_change_token_new, email_change, banned_until
    ) VALUES (
      '00000000-0000-0000-0000-000000000000', v_platform_root,
      'authenticated', 'authenticated',
      'platform-root@kaitong.local',
      crypt(gen_random_uuid()::text, gen_salt('bf')),
      NOW(),
      '{"provider": "system", "providers": ["system"], "is_platform_root": true}'::jsonb,
      '{"nickname": "平台运营中心", "is_platform_root": true}'::jsonb,
      NOW(), NOW(), '', '', '', '',
      'infinity'::timestamptz
    );

    UPDATE public.profiles
       SET nickname = '平台运营中心',
           role = 'manager',
           sub_role = '',
           is_verified = true,
           is_disabled = false
     WHERE id = v_platform_root;

    INSERT INTO public.managers (
      id, business_name, certification_status, membership_level,
      company_name, is_platform_root, created_at, updated_at
    ) VALUES (
      v_platform_root, '平台运营中心', 'approved', 'free',
      '平台运营中心', true, NOW(), NOW()
    );

    INSERT INTO public.enterprises (name, owner_profile_id, created_by)
    VALUES ('平台运营中心', v_platform_root, v_platform_root)
    RETURNING id INTO v_platform_ent;

    UPDATE public.profiles SET enterprise_id = v_platform_ent WHERE id = v_platform_root;
    UPDATE public.managers SET enterprise_id = v_platform_ent WHERE id = v_platform_root;

    PERFORM public.provision_system_health_managers(v_platform_root, v_platform_ent, '平台运营中心');

    INSERT INTO public.system_settings (key, value, description) VALUES
      ('platform_manager_root_id', v_platform_root::text, '平台运营中心根管理师'),
      ('platform_enterprise_id', v_platform_ent::text, '平台运营中心企业')
    ON CONFLICT (key) DO UPDATE
      SET value = EXCLUDED.value, description = EXCLUDED.description, updated_at = NOW();
  END IF;
END;
$function$;