-- 帮耀美开启三个数据可见性模块
UPDATE merchant_module_grants
SET is_enabled = true, updated_at = now()
WHERE manager_id = '5424dfb1-f528-436c-bd75-2028e3c2e286'
  AND module_key IN ('view_health_records', 'view_health_insights', 'view_conversations');