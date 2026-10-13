-- 新增情绪打卡查询技能
INSERT INTO lobster_skills (id, name, slug, description, is_enabled, db_tables, action_type, display_order, created_at)
VALUES (
  gen_random_uuid(),
  '情绪记录查询',
  'query_mood_logs',
  '查询用户的情绪打卡记录，了解近期心情变化趋势和情绪标签分布',
  true,
  ARRAY['mood_logs'],
  'query',
  (SELECT COALESCE(MAX(display_order), 0) + 1 FROM lobster_skills),
  now()
)
ON CONFLICT (slug) DO NOTHING;

-- 新增睡眠打卡查询技能
INSERT INTO lobster_skills (id, name, slug, description, is_enabled, db_tables, action_type, display_order, created_at)
VALUES (
  gen_random_uuid(),
  '睡眠记录查询',
  'query_sleep_logs',
  '查询用户的睡眠打卡数据，分析睡眠时长、质量评分和干扰因素',
  true,
  ARRAY['sleep_logs'],
  'query',
  (SELECT COALESCE(MAX(display_order), 0) + 2 FROM lobster_skills),
  now()
)
ON CONFLICT (slug) DO NOTHING;