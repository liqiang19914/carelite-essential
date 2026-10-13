DROP FUNCTION IF EXISTS public.debug_table_columns(text);
CREATE OR REPLACE FUNCTION public.debug_table_columns(p_table text)
RETURNS TABLE(col_name text, data_type text, col_default text, is_nullable text, col_comments text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT c.column_name::text, c.data_type::text, c.column_default::text, c.is_nullable::text, col_description((p_table)::regclass, ordinal_position)
  FROM information_schema.columns c
  WHERE c.table_schema = 'public' AND c.table_name = p_table
  ORDER BY c.ordinal_position;
$$;
GRANT EXECUTE ON FUNCTION public.debug_table_columns(text) TO anon;
