INSERT INTO merchant_module_grants (manager_id, module_key, grant_status, is_enabled)
VALUES ('5424dfb1-f528-436c-bd75-2028e3c2e286', 'view_health_records', 'granted', false)
ON CONFLICT (manager_id, module_key) DO UPDATE SET grant_status = 'granted', updated_at = now();

INSERT INTO merchant_module_grants (manager_id, module_key, grant_status, is_enabled)
VALUES ('5424dfb1-f528-436c-bd75-2028e3c2e286', 'view_health_insights', 'granted', false)
ON CONFLICT (manager_id, module_key) DO UPDATE SET grant_status = 'granted', updated_at = now();

INSERT INTO merchant_module_grants (manager_id, module_key, grant_status, is_enabled)
VALUES ('5424dfb1-f528-436c-bd75-2028e3c2e286', 'view_conversations', 'granted', false)
ON CONFLICT (manager_id, module_key) DO UPDATE SET grant_status = 'granted', updated_at = now();