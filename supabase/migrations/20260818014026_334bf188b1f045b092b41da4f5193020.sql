-- 商城设置：商城管理下的二级菜单权限
INSERT INTO public.permission_definitions (code, name, node_level, parent_code, permission_kind, sort_order)
VALUES ('shop_settings', '商城设置', 2, 'shop', 'menu', 164)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name,
      node_level = EXCLUDED.node_level,
      parent_code = EXCLUDED.parent_code,
      permission_kind = EXCLUDED.permission_kind,
      sort_order = EXCLUDED.sort_order;

-- 存量补齐：原本能看商品管理的角色，改完仍看得到商城设置（不让任何入口凭空消失）
INSERT INTO public.enterprise_role_permissions (role_id, permission_code)
SELECT DISTINCT erp.role_id, 'shop_settings'
FROM public.enterprise_role_permissions erp
WHERE erp.permission_code IN ('products', 'shop')
ON CONFLICT DO NOTHING;