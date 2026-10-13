-- 邀请码在菜单上已归入「健管师智能体」，角色权限勾选界面同步归位（授权关系按 code 存，不受影响）
UPDATE public.permission_definitions
SET node_level = 2,
    parent_code = 'health_agents',
    sort_order = 136
WHERE code = 'invite';