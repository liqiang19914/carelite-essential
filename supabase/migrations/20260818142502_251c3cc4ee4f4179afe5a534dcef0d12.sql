-- 收藏表只对已登录客户开放读/写自己的行；anon 一律不给（新表默认全授权，必须显式收回）
REVOKE ALL ON TABLE public.user_favorites FROM anon;
REVOKE ALL ON TABLE public.user_favorites FROM authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.user_favorites TO authenticated;