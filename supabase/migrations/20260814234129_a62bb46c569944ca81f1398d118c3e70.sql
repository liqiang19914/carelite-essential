CREATE OR REPLACE FUNCTION public.backfill_conversation_ownership()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count integer;
BEGIN
  WITH roots AS (
    SELECT cr.client_id,
           array_agg(DISTINCT public.get_enterprise_root_manager_id(cr.manager_id)) AS roots
    FROM public.client_relations cr
    WHERE cr.status = 'active'
    GROUP BY cr.client_id
  ),
  single_root AS (
    SELECT client_id, roots[1] AS root_id
    FROM roots
    WHERE array_length(roots, 1) = 1 AND roots[1] IS NOT NULL
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

GRANT EXECUTE ON FUNCTION public.backfill_conversation_ownership() TO service_role;