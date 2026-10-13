CREATE OR REPLACE FUNCTION public.list_store_merchants_open()
RETURNS JSON
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_items JSON;
BEGIN
  SELECT json_agg(t) INTO v_items
  FROM (
    SELECT m.id, m.business_name, m.partner_card_display_name,
           m.partner_card_avatar_url, m.company_name
    FROM public.managers m
    WHERE m.certification_status = 'approved'
      AND public._store_module_on(m.id)
    ORDER BY m.created_at DESC
    LIMIT 100
  ) t;
  RETURN json_build_object('items', COALESCE(v_items, '[]'::JSON));
END;
$function$;