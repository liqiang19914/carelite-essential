-- 声音设置：健管师智能体下的二级菜单权限（原先埋在系统设置的「声音」页签）
INSERT INTO public.permission_definitions (code, name, node_level, parent_code, permission_kind, sort_order)
VALUES ('voice', '声音设置', 2, 'health_agents', 'menu', 135)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name,
      node_level = EXCLUDED.node_level,
      parent_code = EXCLUDED.parent_code,
      permission_kind = EXCLUDED.permission_kind,
      sort_order = EXCLUDED.sort_order;

-- 存量补齐：原本能进系统设置（声音页签所在）或健管师智能体的角色，改完仍能设置声音
INSERT INTO public.enterprise_role_permissions (role_id, permission_code)
SELECT DISTINCT erp.role_id, 'voice'
FROM public.enterprise_role_permissions erp
WHERE erp.permission_code IN ('settings', 'health_agents')
ON CONFLICT DO NOTHING;