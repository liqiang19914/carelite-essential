
-- 为 profiles 表添加子账号角色和权限字段
ALTER TABLE profiles 
  ADD COLUMN IF NOT EXISTS sub_role varchar(50) DEFAULT '' NOT NULL,
  ADD COLUMN IF NOT EXISTS permissions jsonb DEFAULT '{}' NOT NULL;

-- 添加索引优化查询
CREATE INDEX IF NOT EXISTS idx_profiles_sub_role ON profiles (sub_role) WHERE sub_role != '';

-- 添加字段注释
COMMENT ON COLUMN profiles.sub_role IS '子账号角色: owner=主管理员, admin=管理员, service=客服, analyst=数据分析师';
COMMENT ON COLUMN profiles.permissions IS '权限配置JSON: {clients: bool, surveys: bool, export: bool, settings: bool, sub_accounts: bool}';
