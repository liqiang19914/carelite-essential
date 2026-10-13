INSERT INTO public.enterprise_qa_faqs (
  id, enterprise_id, question, answer, keywords, source, created_by, media, enabled, created_at, updated_at
) VALUES (
  'f1f2f3f4-0000-4000-8000-000000003344', '754f0fc2-afb6-4bec-b982-6a701375dbc3',
  '你们的多模态测试问题是什么', '这是多模态素材验证答案', '{}', 'manual',
  '50ed22c9-364b-4933-9972-3e470cbe72cc',
  '[{"id":"m-1","type":"image","url":"https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/qa-media/faq/test.png","name":"测试图"}]',
  true, NOW(), NOW()
);