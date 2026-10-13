-- 存量跨公司错绑治理：解除已确认的那条关系（客户最近进店企业 ≠ 绑定健管师企业）。
-- 保护性断言：固定 UUID + 状态仍为 active + 最近进店企业根确与健管师企业根不一致。
UPDATE public.client_relations cr
SET status = 'inactive', updated_at = NOW()
WHERE cr.id = 'e68fb9d0-5698-4fea-aec6-c8ce50faec56'
  AND cr.status = 'active'
  AND EXISTS (
    SELECT 1
    FROM public.shop_members sm
    WHERE sm.client_id = cr.client_id
      AND sm.created_at = (
        SELECT MAX(sm2.created_at)
        FROM public.shop_members sm2
        WHERE sm2.client_id = cr.client_id
      )
      AND sm.root_manager_id IS DISTINCT FROM (
        SELECT COALESCE(p.parent_manager_id, p.id)
        FROM public.profiles p
        WHERE p.id = cr.manager_id
      )
  );