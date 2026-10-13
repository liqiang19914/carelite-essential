-- 企微助手权限：一级菜单 + 四个子菜单；存量有 clients 权限的角色回填全部新码。
-- 企业负责人 get_my_permissions 自动返回全量，无需单独授权。

INSERT INTO public.permission_definitions (code, name, node_level, parent_code, permission_kind, sort_order, description)
VALUES
  ('wecom_assistant', '企微助手', 1, NULL, 'menu', 105, '企微配置、好友、群与营销工具'),
  ('wecom_settings', '企微配置', 2, 'wecom_assistant', 'menu', 10, '自建应用回调、微信客服与客户联系 Secret 等企微配置'),
  ('wecom_friends', '企微好友', 2, 'wecom_assistant', 'menu', 20, '查看企微好友并与客户建立关联'),
  ('wecom_groups', '企微群列表', 2, 'wecom_assistant', 'menu', 30, '查看企微群与推送记录'),
  ('wecom_tools', '企微营销工具', 2, 'wecom_assistant', 'menu', 40, '群推送、定时推送、小贴士与员工活码')
ON CONFLICT (code) DO NOTHING;

-- 存量角色回填：有客户管理权限的角色补全部企微助手权限
INSERT INTO public.enterprise_role_permissions (role_id, permission_code)
SELECT rp.role_id, c.code
FROM public.enterprise_role_permissions rp
CROSS JOIN (
  VALUES ('wecom_assistant'), ('wecom_settings'), ('wecom_friends'), ('wecom_groups'), ('wecom_tools')
) AS c(code)
WHERE rp.permission_code = 'clients'
ON CONFLICT DO NOTHING;
