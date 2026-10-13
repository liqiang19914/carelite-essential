-- 通用智能体设置权限：健管师智能体 → 通用智能体设置
-- 存量有 agents（智能体管理）权限的角色自动回填。

INSERT INTO public.permission_definitions (code, name, node_level, parent_code, permission_kind, sort_order, description)
VALUES
  ('general_agents_settings', '通用智能体设置', 2, 'health_agents', 'menu', 50, '管理商户通用智能体的开关、名称与 system prompt')
ON CONFLICT (code) DO NOTHING;

-- 存量角色回填：有智能体管理权限的角色补通用智能体设置权限
INSERT INTO public.enterprise_role_permissions (role_id, permission_code)
SELECT DISTINCT rp.role_id, 'general_agents_settings'
FROM public.enterprise_role_permissions rp
WHERE rp.permission_code = 'agents'
ON CONFLICT DO NOTHING;
