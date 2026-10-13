-- 创建精确按手机号查找 auth 用户的函数（避免 listUsers 分页遗漏）
CREATE OR REPLACE FUNCTION find_auth_user_by_phone(p_phone text)
RETURNS jsonb AS $$
  SELECT jsonb_build_object(
    'id', id::text,
    'phone', phone,
    'user_metadata', raw_user_meta_data
  )
  FROM auth.users
  WHERE phone = p_phone
  LIMIT 1;
$$ LANGUAGE sql SECURITY DEFINER;

-- 仅允许 service_role 调用
REVOKE ALL ON FUNCTION find_auth_user_by_phone(text) FROM public;
REVOKE ALL ON FUNCTION find_auth_user_by_phone(text) FROM anon;
REVOKE ALL ON FUNCTION find_auth_user_by_phone(text) FROM authenticated;