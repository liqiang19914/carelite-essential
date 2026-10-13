-- 删除 profiles 表上所有现有的 RLS 策略
DROP POLICY IF EXISTS "Admins can view all profiles" ON profiles;
DROP POLICY IF EXISTS "Admins can update all profiles" ON profiles;
DROP POLICY IF EXISTS "Users can view own profile" ON profiles;
DROP POLICY IF EXISTS "Users can update own profile" ON profiles;
DROP POLICY IF EXISTS "Users can insert own profile" ON profiles;

-- 创建一个 SECURITY DEFINER 函数来检查用户是否是管理员（绕过 RLS）
CREATE OR REPLACE FUNCTION public.is_admin(user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = user_id AND role = 'admin'
  );
$$;

-- 重新创建 RLS 策略（避免自引用）
-- 用户可以查看自己的 profile，或者管理员可以查看所有
CREATE POLICY "profiles_select_policy"
  ON profiles FOR SELECT
  USING (
    auth.uid() = id 
    OR public.is_admin(auth.uid())
  );

-- 用户可以更新自己的 profile，或者管理员可以更新所有
CREATE POLICY "profiles_update_policy"
  ON profiles FOR UPDATE
  USING (
    auth.uid() = id 
    OR public.is_admin(auth.uid())
  );

-- 触发器可以插入 profile（用于新用户注册）
CREATE POLICY "profiles_insert_policy"
  ON profiles FOR INSERT
  WITH CHECK (auth.uid() = id);