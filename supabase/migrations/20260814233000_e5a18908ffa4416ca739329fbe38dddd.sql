CREATE OR REPLACE FUNCTION public.backfill_conversation_ownership()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count integer;
BEGIN
  WITH single_root AS (
    SELECT cr.client_id,
           MIN(public.get_enterprise_root_manager_id(cr.manager_id)) AS root_id
    FROM public.client_relations cr
    WHERE cr.status = 'active'
    GROUP BY cr.client_id
    HAVING COUNT(DISTINCT public.get_enterprise_root_manager_id(cr.manager_id)) = 1
       AND MIN(public.get_enterprise_root_manager_id(cr.manager_id)) IS NOT NULL
  )
  UPDATE public.conversations c
  SET owner_manager_id = sr.root_id
  FROM single_root sr
  WHERE c.user_id = sr.client_id
    AND c.owner_manager_id IS NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.backfill_conversation_ownership() FROM PUBLIC;