-- 1.A.9: switch default model + raise max_tokens hotfix
-- 把 1.A.5 出厂默认 text_model='qwen3-max' 调整为更快的 deepseek-chat（B 中庸方案）
-- 把 1.A.6 调低的 max_tokens=2048 回升到 4096（精简到 3 字段后 4096 给 2× 安全余量）
-- 用 WHERE 限定原始默认值，避免覆盖超管手调过的内容。
UPDATE public.survey_creator_agent
SET text_model = 'deepseek-chat',
    updated_at = now()
WHERE text_model = 'qwen3-max';

UPDATE public.survey_creator_agent
SET max_tokens = 4096,
    updated_at = now()
WHERE max_tokens = 2048;