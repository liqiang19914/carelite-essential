-- 两个演示店的商品触发器已自动建默认 SKU；仅保留有实际演示价格的 SKU 为默认项。
WITH ranked AS (
  SELECT
    sku.id,
    row_number() OVER (
      PARTITION BY sku.product_id
      ORDER BY sku.price_cents DESC, sku.created_at DESC, sku.id
    ) AS position
  FROM public.product_skus sku
  JOIN public.products product ON product.id = sku.product_id
  WHERE product.owner_manager_id IN (
    'c6cc187c-3b13-40fc-befb-aa70594ebe3c'::uuid,
    'bfb89a01-4c1c-43fc-bce0-fe18e0401b4e'::uuid
  )
    AND sku.is_active = true
)
UPDATE public.product_skus sku
SET is_default = ranked.position = 1,
    updated_at = now()
FROM ranked
WHERE sku.id = ranked.id;
