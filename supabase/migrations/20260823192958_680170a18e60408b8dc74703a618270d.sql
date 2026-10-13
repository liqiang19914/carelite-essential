-- 281: AI 回答可附课程卡片（结构化消息）
ALTER TABLE public.manager_public_qa_messages ADD COLUMN IF NOT EXISTS course_card jsonb;