-- 列出所有 owner_manager_id = 5424dfb1 的 conversations，看 user_id 是谁、有没有 body_composition 关联
DROP FUNCTION IF EXISTS public.debug_conv_users_5424();
CREATE OR REPLACE FUNCTION public.debug_conv_users_5424()
RETURNS TABLE(user_id uuid, nick varchar(100), ent_id uuid, client_of_5424 boolean, convs bigint, bc_records bigint, conv_titles text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    DISTINCT c.user_id,
    p.nickname,
    p.enterprise_id,
    EXISTS (SELECT 1 FROM public.client_relations cr WHERE cr.client_id = c.user_id AND cr.status = 'active' AND cr.manager_id = '5424dfb1-f528-436c-bd75-2028e3c2e286'),
    (SELECT COUNT(*) FROM public.conversations c2 WHERE c2.user_id = c.user_id AND c2.owner_manager_id = '5424dfb1-f528-436c-bd75-2028e3c2e286')::bigint,
    (SELECT COUNT(*) FROM public.body_compositions bc WHERE bc.record_id IN (SELECT hr.id FROM public.health_records hr WHERE hr.user_id = c.user_id))::bigint,
    (SELECT string_agg(c3.title, ' || ' ORDER BY c3.created_at DESC) FROM public.conversations c3 WHERE c3.user_id = c.user_id AND c3.owner_manager_id = '5424dfb1-f528-436c-bd75-2028e3c2e286')
  FROM public.conversations c
  JOIN public.profiles p ON p.id = c.user_id
  WHERE c.owner_manager_id = '5424dfb1-f528-436c-bd75-2028e3c2e286'
  ORDER BY convs DESC;
END;
$$;
GRANT EXECUTE ON FUNCTION public.debug_conv_users_5424() TO anon;
