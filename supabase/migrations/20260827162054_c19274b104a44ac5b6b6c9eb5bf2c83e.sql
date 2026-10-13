CREATE OR REPLACE FUNCTION public.get_client_assignment_history(p_client_id uuid)
RETURNS TABLE (
  id uuid,
  from_manager_id uuid,
  from_name text,
  to_manager_id uuid,
  to_name text,
  operated_by uuid,
  operator_name text,
  reason text,
  customer_name_snapshot text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_manager_id uuid := auth.uid();
  v_root uuid;
  v_has_relation boolean;
BEGIN
  IF v_manager_id IS NULL THEN
    RAISE EXCEPTION '未登录' USING ERRCODE = '28000';
  END IF;

  v_root := public.get_enterprise_root_manager_id(v_manager_id);

  SELECT EXISTS (
    SELECT 1 FROM public.client_relations cr
    WHERE cr.client_id = p_client_id
      AND cr.manager_id IN (
        SELECT v_root AS mid
        UNION
        SELECT p.id FROM public.profiles p
        WHERE p.parent_manager_id = v_root AND p.role = 'manager'
      )
  ) INTO v_has_relation;

  IF NOT v_has_relation THEN
    RAISE EXCEPTION '无权查看该客户的归属历史' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT h.id,
         h.from_manager_id,
         COALESCE(fp.nickname::text, ''),
         h.to_manager_id,
         COALESCE(tp.nickname::text, ''),
         h.operated_by,
         COALESCE(op.nickname::text, ''),
         COALESCE(h.reason, ''::text),
         COALESCE(h.customer_name_snapshot, ''::text),
         h.created_at
  FROM public.client_assignment_history h
  LEFT JOIN public.profiles fp ON fp.id = h.from_manager_id
  LEFT JOIN public.profiles tp ON tp.id = h.to_manager_id
  LEFT JOIN public.profiles op ON op.id = h.operated_by
  WHERE h.client_id = p_client_id
    AND (h.root_manager_id = v_root OR h.root_manager_id IS NULL)
  ORDER BY h.created_at DESC;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_client_assignment_history(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_client_assignment_history(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_client_assignment_history(uuid) FROM anon;