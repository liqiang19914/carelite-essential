-- 删除旧函数重载，避免 PostgREST 按命名参数解析时出现「函数不唯一」歧义
DROP FUNCTION IF EXISTS public.list_enterprise_reputation_posts(uuid, integer, integer);
DROP FUNCTION IF EXISTS public.moderate_reputation_post(uuid, text, text);
