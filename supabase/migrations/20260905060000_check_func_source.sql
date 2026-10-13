-- 查远程DB上 list_manager_conversations 的源码，确认是不是最新版本
DROP FUNCTION IF EXISTS public.debug_function_source(text);
CREATE OR REPLACE FUNCTION public.debug_function_source(p_func_name text)
RETURNS TABLE(source text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT prosrc FROM pg_proc WHERE proname = p_func_name;
$$;
GRANT EXECUTE ON FUNCTION public.debug_function_source(text) TO anon;
