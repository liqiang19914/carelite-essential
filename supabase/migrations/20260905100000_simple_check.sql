-- 不带参数，直接查硬编码的卓越耀美 root
DROP FUNCTION IF EXISTS public.debug_simple_check();
CREATE OR REPLACE FUNCTION public.debug_simple_check()
RETURNS TABLE(total_null bigint, total_root bigint, total_ent_match bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT 
    (SELECT COUNT(*) FROM public.conversations WHERE owner_manager_id IS NULL)::bigint,
    (SELECT COUNT(*) FROM public.conversations WHERE owner_manager_id = '5424dfb1-f528-436c-bd75-2028e3c2e286')::bigint,
    (SELECT COUNT(*) FROM public.conversations c JOIN public.profiles p ON p.id=c.user_id WHERE c.owner_manager_id IS NULL AND p.enterprise_id = '34e40e3b-eb9c-46c6-a9f2-dcf197262509')::bigint;
$$;
GRANT EXECUTE ON FUNCTION public.debug_simple_check() TO anon;
