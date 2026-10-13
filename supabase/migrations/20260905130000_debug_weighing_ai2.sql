DROP FUNCTION IF EXISTS public.debug_weighing_ai_diagnose();
CREATE OR REPLACE FUNCTION public.debug_weighing_ai_diagnose()
RETURNS TABLE(
  nick varchar(100),
  uid uuid,
  ent_id uuid,
  records bigint,
  comps bigint,
  convs bigint,
  convs_root bigint,
  convs_null bigint,
  convs_other bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    p.nickname,
    p.id,
    p.enterprise_id,
    (SELECT COUNT(*) FROM public.metrics_profile_records pr WHERE pr.user_id = p.id)::bigint AS records,
    (SELECT COUNT(*) FROM public.body_compositions bc WHERE bc.record_id IN (SELECT pr2.id FROM public.metrics_profile_records pr2 WHERE pr2.user_id = p.id))::bigint AS comps,
    (SELECT COUNT(*) FROM public.conversations c WHERE c.user_id = p.id)::bigint AS convs,
    (SELECT COUNT(*) FROM public.conversations c WHERE c.user_id = p.id AND c.owner_manager_id = '5424dfb1-f528-436c-bd75-2028e3c2e286')::bigint AS convs_root,
    (SELECT COUNT(*) FROM public.conversations c WHERE c.user_id = p.id AND c.owner_manager_id IS NULL)::bigint AS convs_null,
    (SELECT COUNT(*) FROM public.conversations c WHERE c.user_id = p.id AND c.owner_manager_id IS NOT NULL AND c.owner_manager_id != '5424dfb1-f528-436c-bd75-2028e3c2e286')::bigint AS convs_other
  FROM public.client_relations cr
  JOIN public.profiles p ON p.id = cr.client_id
  WHERE cr.status = 'active' AND cr.manager_id = '5424dfb1-f528-436c-bd75-2028e3c2e286'
    AND p.role = 'user'
    AND EXISTS (SELECT 1 FROM public.body_compositions bc WHERE bc.record_id IN (SELECT pr.id FROM public.metrics_profile_records pr WHERE pr.user_id = p.id))
  ORDER BY comps DESC, convs DESC
  LIMIT 15;
END;
$$;
GRANT EXECUTE ON FUNCTION public.debug_weighing_ai_diagnose() TO anon;
