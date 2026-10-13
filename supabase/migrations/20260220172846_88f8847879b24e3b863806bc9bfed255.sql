-- 修复：为 service_role 角色添加 EXECUTE 权限，并增强手机号匹配兼容性
CREATE OR REPLACE FUNCTION find_auth_user_by_phone(p_phone text)
RETURNS jsonb AS $$
  SELECT jsonb_build_object(
    'id', id::text,
    'phone', phone,
    'user_metadata', raw_user_meta_data
  )
  FROM auth.users
  WHERE phone = p_phone
     OR phone = '+' || ltrim(p_phone, '+')
     OR phone = ltrim(p_phone, '+')
  LIMIT 1;
$$ LANGUAGE sql SECURITY DEFINER;

-- 确保 service_role 有执行权限
GRANT EXECUTE ON FUNCTION find_auth_user_by_phone(text) TO service_role;

-- 保持安全性：阻止前端直接调用
REVOKE ALL ON FUNCTION find_auth_user_by_phone(text) FROM anon;
REVOKE ALL ON FUNCTION find_auth_user_by_phone(text) FROM authenticated;