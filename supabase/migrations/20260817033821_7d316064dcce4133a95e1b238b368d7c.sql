ALTER TABLE public.managers ADD COLUMN IF NOT EXISTS is_recommended BOOLEAN NOT NULL DEFAULT FALSE;
COMMENT ON COLUMN public.managers.is_recommended IS '推荐管理师标记：true 时在用户端「更多健康管理师」置顶并打推荐标。';