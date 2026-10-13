ALTER TABLE merchant_module_grants DROP CONSTRAINT mmg_module_key_check;
ALTER TABLE merchant_module_grants ADD CONSTRAINT mmg_module_key_check
  CHECK (module_key = ANY (ARRAY['shop_order_lifecycle', 'points_exchange', 'view_health_records', 'view_health_insights', 'view_conversations']));