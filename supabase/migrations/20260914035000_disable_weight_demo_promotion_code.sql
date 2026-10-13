-- 演示分销记录仅供后台预览，不接受真实客户绑定。
UPDATE public.promotion_codes
SET is_active = false
WHERE id = '35768af2-6437-4190-bc23-98a484717431'
  AND enterprise_root_id = '9d20bc6b-cbd4-4153-84e5-01e5b58f041f'
  AND is_active = true;
