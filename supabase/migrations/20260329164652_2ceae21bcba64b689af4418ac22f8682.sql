-- 清除孤儿账号 (7ad7c966) 的 wechat_openid
UPDATE profiles
SET wechat_openid = '', wechat_nickname = '', wechat_avatar = '', wechat_unionid = '', updated_at = now()
WHERE id = '7ad7c966-4e20-4af1-8df9-9ec81d73cb60';