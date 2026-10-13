-- 删除 managers 表上有问题的 RLS 策略
DROP POLICY IF EXISTS "Admins can view all managers" ON managers;
DROP POLICY IF EXISTS "Admins can update all managers" ON managers;

-- 重新创建 managers 表的 RLS 策略（使用 is_admin 函数避免递归）
CREATE POLICY "managers_select_policy"
  ON managers FOR SELECT
  USING (
    auth.uid() = id 
    OR public.is_admin(auth.uid())
  );

CREATE POLICY "managers_update_policy"
  ON managers FOR UPDATE
  USING (
    auth.uid() = id 
    OR public.is_admin(auth.uid())
  );