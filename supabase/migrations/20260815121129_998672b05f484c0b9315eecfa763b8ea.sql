ALTER TABLE public.manager_miniapp_code_cache
  ALTER COLUMN manager_id DROP NOT NULL;

ALTER TABLE public.manager_miniapp_code_cache
  ADD COLUMN IF NOT EXISTS product_id uuid REFERENCES public.products(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_manager_miniapp_code_cache_product_id
  ON public.manager_miniapp_code_cache(product_id);