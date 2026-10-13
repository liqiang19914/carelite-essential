DROP FUNCTION IF EXISTS public.manager_weighing_people(text, date, date, integer, integer);
DROP FUNCTION IF EXISTS public.admin_weighing_people(uuid, text, date, date, integer, integer);

REVOKE ALL ON FUNCTION public.manager_weighing_people(text, date, date, text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.manager_weighing_people(text, date, date, text, integer, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.manager_weighing_people(text, date, date, text, integer, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_weighing_people(uuid, text, date, date, text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_weighing_people(uuid, text, date, date, text, integer, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_weighing_people(uuid, text, date, date, text, integer, integer) TO authenticated;