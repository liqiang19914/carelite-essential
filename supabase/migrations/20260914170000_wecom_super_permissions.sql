DELETE FROM public.permission_definitions WHERE code LIKE 'wecom_super%';

INSERT INTO public.permission_definitions (code, name, node_level, parent_code, permission_kind, sort_order)
VALUES ('wecom_super', '企微超级助手', 1, NULL, 'menu', 107);

INSERT INTO public.permission_definitions (code, name, node_level, parent_code, permission_kind, sort_order) VALUES
  ('wecom_super_devices',       '外挂账号',    2, 'wecom_super', 'menu', 10),
  ('wecom_super_contacts',      '好友列表',    2, 'wecom_super', 'menu', 20),
  ('wecom_super_rooms',         '群列表',      2, 'wecom_super', 'menu', 30),
  ('wecom_super_private_mass',  '私信群发',    2, 'wecom_super', 'menu', 40),
  ('wecom_super_group_mass',    '群消息群发',  2, 'wecom_super', 'menu', 50),
  ('wecom_super_tasks',         '发送任务',    2, 'wecom_super', 'menu', 60),
  ('wecom_super_messages',      '消息记录',    2, 'wecom_super', 'menu', 70),
  ('wecom_super_ai',            'AI 智能营销', 2, 'wecom_super', 'menu', 80),
  ('wecom_super_settings',      '设置',        2, 'wecom_super', 'menu', 90);

SELECT code, name, node_level, parent_code, sort_order FROM public.permission_definitions WHERE code LIKE 'wecom_super%' ORDER BY node_level, sort_order;
