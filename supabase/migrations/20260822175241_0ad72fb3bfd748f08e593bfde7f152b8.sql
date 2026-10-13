-- 249 验证：临时禁用测试商户以验证禁用态拦截（验证后立即恢复）
UPDATE public.profiles SET is_disabled = true WHERE id = '31685996-3218-4b31-bd05-7128beee7426';