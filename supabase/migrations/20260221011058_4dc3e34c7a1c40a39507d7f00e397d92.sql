-- 先检查是否存在 admin 邮箱的用户，然后创建
-- Step 1: 创建 auth user（如果不存在）
DO $$
DECLARE
  v_admin_id uuid;
BEGIN
  -- 检查是否已存在
  SELECT id INTO v_admin_id FROM auth.users WHERE email = 'admin@caplinkai.com';
  
  IF v_admin_id IS NOT NULL THEN
    RAISE NOTICE 'Admin user already exists with id: %', v_admin_id;
    -- 确保密码正确
    UPDATE auth.users 
    SET encrypted_password = crypt('CapLink@2026!', gen_salt('bf')),
        updated_at = now()
    WHERE id = v_admin_id;
    
    -- 确保 identity 记录存在
    INSERT INTO auth.identities (id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
    VALUES (v_admin_id, v_admin_id, jsonb_build_object('sub', v_admin_id::text, 'email', 'admin@caplinkai.com'), 'email', v_admin_id::text, now(), now(), now())
    ON CONFLICT DO NOTHING;
    
    -- 确保 profile 角色正确
    UPDATE profiles SET role = 'admin', nickname = '超级管理员', is_verified = true WHERE id = v_admin_id;
  ELSE
    -- 创建新用户
    v_admin_id := gen_random_uuid();
    
    INSERT INTO auth.users (
      id, instance_id, email, encrypted_password,
      email_confirmed_at, role, aud,
      raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at,
      confirmation_token, email_change, email_change_token_new, recovery_token
    ) VALUES (
      v_admin_id, '00000000-0000-0000-0000-000000000000',
      'admin@caplinkai.com', crypt('CapLink@2026!', gen_salt('bf')),
      now(), 'authenticated', 'authenticated',
      '{"provider": "email", "providers": ["email"]}'::jsonb,
      '{"nickname": "超级管理员"}'::jsonb,
      now(), now(), '', '', '', ''
    );
    
    INSERT INTO auth.identities (id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
    VALUES (v_admin_id, v_admin_id, jsonb_build_object('sub', v_admin_id::text, 'email', 'admin@caplinkai.com'), 'email', v_admin_id::text, now(), now(), now());
    
    -- 等一下 trigger 创建 profile，然后更新角色
    UPDATE profiles SET role = 'admin', nickname = '超级管理员', is_verified = true, real_name = '系统管理员' WHERE id = v_admin_id;
    
    RAISE NOTICE 'Admin user created with id: %', v_admin_id;
  END IF;
END $$;