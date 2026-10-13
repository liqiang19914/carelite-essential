INSERT INTO public.lobster_skills (name, slug, description, is_enabled, db_tables, action_type, display_order)
SELECT
  '体成分数据查询',
  'query_body_composition',
  '查询用户的体成分测量记录（智能体脂秤测量或手动录入），包括体重、BMI、体脂率、水分率、骨骼肌率、内脏脂肪等级、基础代谢、身体年龄、体型等指标，可指定家庭成员',
  true,
  ARRAY['body_compositions', 'health_records']::text[],
  'query',
  18
WHERE NOT EXISTS (
  SELECT 1 FROM public.lobster_skills WHERE slug = 'query_body_composition'
);