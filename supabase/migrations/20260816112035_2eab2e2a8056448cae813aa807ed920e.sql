CREATE OR REPLACE FUNCTION public.admin_archive_manager_product(p_id uuid)
 RETURNS products
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row products;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'forbidden: admin role required';
  END IF;

  UPDATE products
  SET status = 'archived'
  WHERE id = p_id
    AND source_type = 'manager'
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION '商品不存在或不是私域商品';
  END IF;

  RETURN v_row;
END;
$function$