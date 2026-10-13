
-- 移除 profiles.id 对 auth.users.id 的外键约束
-- 允许管理端为未注册用户创建客户档案
ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_id_fkey;
