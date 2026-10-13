-- 1.A.6: 把 survey_creator_agent 表里仍保持出厂默认 max_tokens=4096 的那一行调整为 2048
-- 与体检报告解读路径（max_tokens=2000）对齐。问卷结构化 JSON 输出实测 1500-2000 tokens 内。
-- 超管在「问卷管理 → 智能体」面板内可随时调高（CHECK 上限 8192）。
-- 只更新仍是出厂默认 4096 的行，不会覆盖超管已经手动改过的值。
UPDATE public.survey_creator_agent
SET max_tokens = 2048,
    updated_at = now()
WHERE max_tokens = 4096;