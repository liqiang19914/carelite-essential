-- 订阅消息模板配置
INSERT INTO system_settings (key, value, description) VALUES
  ('miniapp_tpl_health',  '', '健康提醒订阅消息模板ID'),
  ('miniapp_tpl_survey',  '', '问卷通知订阅消息模板ID'),
  ('miniapp_tpl_consult', '', '咨询回复订阅消息模板ID')
ON CONFLICT (key) DO NOTHING;
