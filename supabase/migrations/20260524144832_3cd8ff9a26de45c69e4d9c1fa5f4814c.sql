CREATE OR REPLACE FUNCTION public.bump_product_view(p_product_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE products SET view_count = view_count + 1 WHERE id = p_product_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.bump_product_view(UUID) TO anon, authenticated;
