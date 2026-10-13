
-- 放宽 profiles INSERT 策略：任何已登录用户可以创建新的 profile 条目
-- 应用层（ProtectedRoute）已控制页面访问权限，RLS 只需确保已认证即可
DROP POLICY IF EXISTS "profiles_insert_policy" ON profiles;

CREATE POLICY "profiles_insert_policy"
  ON profiles FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);
