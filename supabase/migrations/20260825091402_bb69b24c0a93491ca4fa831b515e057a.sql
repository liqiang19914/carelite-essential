ALTER TABLE public.merchant_module_grants DROP CONSTRAINT IF EXISTS mmg_module_key_check;

ALTER TABLE public.merchant_module_grants ADD CONSTRAINT mmg_module_key_check
CHECK (module_key = ANY (ARRAY[
  'shop_order_lifecycle', 'points_exchange', 'stores',
  'view_conversations', 'view_health_insights', 'view_health_records',
  'native_login', 'marketing_center'
]::text[]));