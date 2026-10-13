BEGIN;
DO $function$
DECLARE
  v_test uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at, confirmation_token, recovery_token,
    email_change_token_new, email_change, banned_until
  ) VALUES (
    '00000000-0000-0000-0000-000000000000', v_test,
    'authenticated', 'authenticated',
    'probe-test@kaitong.local',
    crypt(gen_random_uuid()::text, gen_salt('bf')),
    NOW(),
    '{"provider": "system", "providers": ["system"]}'::jsonb,
    '{"nickname": "探针"}'::jsonb,
    NOW(), NOW(), '', '', '', '',
    'infinity'::timestamptz
  );
  RAISE NOTICE 'auth insert ok %', v_test;
END;
$function$;
ROLLBACK;