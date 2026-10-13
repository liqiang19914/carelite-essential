-- 清掉旧 3 参重载，只保留带并发期望的 5 参版本，避免 PostgREST PGRST203 歧义
DROP FUNCTION IF EXISTS public.set_reputation_post_display(uuid, integer, boolean);