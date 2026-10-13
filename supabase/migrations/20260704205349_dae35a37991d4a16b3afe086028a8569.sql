DROP INDEX IF EXISTS idx_profiles_wechat_unionid;

CREATE UNIQUE INDEX idx_profiles_wechat_unionid_role
  ON profiles (wechat_unionid, role)
  WHERE wechat_unionid != '';