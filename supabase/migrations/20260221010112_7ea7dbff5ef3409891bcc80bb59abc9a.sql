-- 找到刚创建的 admin 用户并更新其 profile
UPDATE profiles
SET 
  role = 'admin',
  nickname = '超级管理员',
  is_verified = true,
  real_name = '系统管理员'
WHERE id = (
  SELECT id FROM auth.users WHERE email = 'admin@caplinkai.com' LIMIT 1
);