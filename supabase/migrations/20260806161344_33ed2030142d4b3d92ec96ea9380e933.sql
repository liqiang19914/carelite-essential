-- 收紧：这两个函数体内第一步就要求 auth.uid() 且必须是管理员/企业成员，
-- 匿名角色调用注定失败，但默认权限会在 DROP+CREATE 后把 EXECUTE 重新授予 anon，
-- 这里显式收回，避免把无用的调用面暴露在外。
REVOKE EXECUTE ON FUNCTION public.admin_content_action(uuid, text, text, timestamptz) FROM anon;
REVOKE EXECUTE ON FUNCTION public.publish_content(uuid) FROM anon;