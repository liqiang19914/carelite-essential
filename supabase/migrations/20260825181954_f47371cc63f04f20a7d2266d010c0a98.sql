INSERT INTO public.enterprise_qa_faqs (
  id, enterprise_id, question, answer, keywords, source, created_by, media, enabled, created_at, updated_at
) VALUES (
  'f1f2f3f4-0000-4000-8000-000000003345', 'b94604cd-a1b4-4d8f-87de-6fb37a6cad26',
  '多模态素材验证问题三千六百七十二', '这是带素材的标准答案', '{}', 'manual',
  'a6f5c22f-33ec-411f-ad26-3777ebbb534e',
  '[{"id":"m-1","type":"image","url":"https://hms-caplinkai.oss-cn-beijing.aliyuncs.com/qa-media/faq/verify-demo.png","name":"演示配图"}]',
  true, NOW(), NOW()
);