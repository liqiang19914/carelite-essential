-- feature 149：客户数据可见性与智能体编辑改为角色「特殊权限」逐项勾选
-- 1) 权限项加说明列，勾选界面可以逐条讲清楚授予后能看到什么
ALTER TABLE public.permission_definitions ADD COLUMN IF NOT EXISTS description text;

-- 2) 新增「查看客户健康档案」特殊权限
INSERT INTO public.permission_definitions (code, name, node_level, parent_code, permission_kind, sort_order, description)
VALUES (
  'view_health_records', '查看客户健康档案', 1, NULL, 'action', 110,
  '可在客户详情里查看健康档案、体征记录与体检报告。客户本人关闭共享时依然看不到。'
)
ON CONFLICT (code) DO UPDATE
SET name = EXCLUDED.name,
    node_level = EXCLUDED.node_level,
    parent_code = EXCLUDED.parent_code,
    permission_kind = EXCLUDED.permission_kind,
    sort_order = EXCLUDED.sort_order,
    description = EXCLUDED.description;

-- 3) 健康洞察 / AI 对话由「菜单权限」移入「特殊权限」（权限码不变，已勾选记录全部保留）
UPDATE public.permission_definitions
SET name = '查看健康洞察', permission_kind = 'action', node_level = 1, parent_code = NULL, sort_order = 111,
    description = '可进入「健康洞察」页，查看名下客户的 AI 健康分析结果。客户关闭数据分析共享时不展示。'
WHERE code = 'health_insights';

UPDATE public.permission_definitions
SET name = '查看客户 AI 对话', permission_kind = 'action', node_level = 1, parent_code = NULL, sort_order = 112,
    description = '可进入「AI 对话」页，查看名下客户与智能体的聊天记录。客户关闭数据分析共享时不展示。'
WHERE code = 'conversations';

-- 4) 编辑他人智能体：正式启用为可授予权限
UPDATE public.permission_definitions
SET name = '编辑他人的智能体', sort_order = 113,
    description = '可克隆、发布并代为训练其他健管师的智能体。本人自己的智能体不受此权限限制。'
WHERE code = 'agent_edit';

UPDATE public.permission_definitions
SET sort_order = 100, description = '可导出商户经营数据（订单、商品、内容等报表）。'
WHERE code = 'data_export';

UPDATE public.permission_definitions
SET sort_order = 101, description = '可导出客户名单与客户数据，属于高敏感操作，建议只给必要角色。'
WHERE code = 'user_data_export';

-- 5) 存量回填：搬迁前只要能进「客户管理」就能看到客户档案，
--    因此给所有持有 clients 的角色补上 view_health_records，保证改完可见数据不减少。
INSERT INTO public.enterprise_role_permissions (role_id, permission_code)
SELECT DISTINCT rp.role_id, 'view_health_records'
FROM public.enterprise_role_permissions rp
WHERE rp.permission_code = 'clients'
ON CONFLICT DO NOTHING;

-- 6) 超管 / 管理员角色兜底：四项特殊权限全部补齐
INSERT INTO public.enterprise_role_permissions (role_id, permission_code)
SELECT r.id, c.code
FROM public.enterprise_roles r
CROSS JOIN (VALUES ('view_health_records'), ('health_insights'), ('conversations'), ('agent_edit')) AS c(code)
WHERE r.code IN ('super_admin', 'admin') OR r.is_owner_role = true
ON CONFLICT DO NOTHING;