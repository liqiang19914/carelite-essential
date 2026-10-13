-- 将 wechat_openid 全局唯一索引改为 (wechat_openid, role) 组合唯一
-- 允许同一个微信绑定不同角色的账号（管理师+用户），但禁止同角色重复绑定
DROP INDEX IF EXISTS idx_profiles_wechat_openid;

CREATE UNIQUE INDEX idx_profiles_wechat_openid_role
  ON profiles (wechat_openid, role)
  WHERE wechat_openid IS NOT NULL AND wechat_openid != '';