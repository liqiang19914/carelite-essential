
-- 创建 manager 角色检查函数（SECURITY DEFINER 避免 RLS 自引用）
CREATE OR REPLACE FUNCTION public.is_manager(user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = user_id AND role = 'manager'
  );
$$;

-- 删除现有策略并重建
DROP POLICY IF EXISTS "profiles_select_policy" ON profiles;
DROP POLICY IF EXISTS "profiles_update_policy" ON profiles;
DROP POLICY IF EXISTS "profiles_insert_policy" ON profiles;

-- SELECT: 自己 + 管理员 + 管理端
CREATE POLICY "profiles_select_policy"
  ON profiles FOR SELECT
  USING (
    auth.uid() = id
    OR public.is_admin(auth.uid())
    OR public.is_manager(auth.uid())
  );

-- UPDATE: 自己 + 管理员 + 管理端
CREATE POLICY "profiles_update_policy"
  ON profiles FOR UPDATE
  USING (
    auth.uid() = id
    OR public.is_admin(auth.uid())
    OR public.is_manager(auth.uid())
  );

-- INSERT: 自己注册 + 管理员 + 管理端创建客户
CREATE POLICY "profiles_insert_policy"
  ON profiles FOR INSERT
  WITH CHECK (
    auth.uid() = id
    OR public.is_admin(auth.uid())
    OR public.is_manager(auth.uid())
  );
