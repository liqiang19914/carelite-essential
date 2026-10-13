-- 1. 修复问卷提交bug: respondent_id 改为可空（允许匿名填写）
ALTER TABLE survey_responses ALTER COLUMN respondent_id DROP NOT NULL;

-- 2. 给 profiles 添加 invited_by 字段（记录邀请人）
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS invited_by uuid REFERENCES profiles(id);
COMMENT ON COLUMN profiles.invited_by IS '邀请注册的管理端用户ID，通过二维码邀请绑定';

-- 3. 给 invited_by 加索引
CREATE INDEX IF NOT EXISTS idx_profiles_invited_by ON profiles(invited_by) WHERE invited_by IS NOT NULL;