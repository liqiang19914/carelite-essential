-- ============================================================
-- 权限定义种子 + 内置五角色 + 自动播种触发器 + 现有企业回填
-- ============================================================

-- 1) 权限定义种子（菜单树 + 动作权限）
INSERT INTO public.permission_definitions (code, name, node_level, parent_code, permission_kind, sort_order) VALUES
  ('dashboard', '仪表盘', 1, NULL, 'menu', 1),
  ('stats', '数据统计', 1, NULL, 'menu', 2),
  ('clients', '客户管理', 1, NULL, 'menu', 10),
  ('weighing', '称重数据', 1, NULL, 'menu', 11),
  ('ownership', '归属管理', 1, NULL, 'menu', 12),
  ('health_agents', '健管师智能体', 1, NULL, 'menu', 13),
  ('health_managers', '健管师管理', 2, 'health_agents', 'menu', 131),
  ('agents', '智能体管理', 2, 'health_agents', 'menu', 132),
  ('knowledge', '知识库训练', 2, 'health_agents', 'menu', 133),
  ('qa', '问答入口', 2, 'health_agents', 'menu', 134),
  ('surveys', '问卷管理', 1, NULL, 'menu', 14),
  ('content', '内容管理', 1, NULL, 'menu', 15),
  ('shop', '商城管理', 1, NULL, 'menu', 16),
  ('products', '商品管理', 2, 'shop', 'menu', 161),
  ('orders', '订单记录', 2, 'shop', 'menu', 162),
  ('reputation', '评价管理', 2, 'shop', 'menu', 163),
  ('decorate', '店铺装修', 1, NULL, 'menu', 17),
  ('diet_map', '饮食导图', 1, NULL, 'menu', 18),
  ('health_insights', '健康洞察', 1, NULL, 'menu', 19),
  ('conversations', 'AI 对话', 1, NULL, 'menu', 20),
  ('live', '直播间', 1, NULL, 'menu', 21),
  ('logs', '管理记录', 1, NULL, 'menu', 30),
  ('invite', '邀请码', 1, NULL, 'menu', 31),
  ('enterprise_members', '企业成员管理', 1, NULL, 'menu', 40),
  ('enterprise_roles', '角色权限', 1, NULL, 'menu', 41),
  ('miniprogram', '我的小程序', 1, NULL, 'menu', 42),
  ('settings', '系统设置', 1, NULL, 'menu', 43),
  ('data_export', '数据导出', 1, NULL, 'action', 100),
  ('agent_edit', '管理师智能体修改', 1, NULL, 'action', 101),
  ('user_data_export', '用户数据导出', 1, NULL, 'action', 102)
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name,
  node_level = EXCLUDED.node_level,
  parent_code = EXCLUDED.parent_code,
  permission_kind = EXCLUDED.permission_kind,
  sort_order = EXCLUDED.sort_order;

-- 2) 默认角色播种函数（新企业自动调用）
CREATE OR REPLACE FUNCTION public.seed_enterprise_default_roles_fn(p_enterprise_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  r_super uuid;
  r_admin uuid;
  r_operator uuid;
  r_hm uuid;
  r_finance uuid;
BEGIN
  INSERT INTO public.enterprise_roles (enterprise_id, code, name, description, is_system, is_owner_role) VALUES
    (p_enterprise_id, 'super_admin', '超级管理员', '企业主，拥有全部权限', true, true),
    (p_enterprise_id, 'admin', '管理员', '企业管理员', true, false),
    (p_enterprise_id, 'operator', '运营', '内容与商城运营', true, false),
    (p_enterprise_id, 'health_manager', '健康管理师', '服务客户并维护自己的智能体', true, false),
    (p_enterprise_id, 'finance', '财务', '查看订单与数据导出', true, false)
  ON CONFLICT (enterprise_id, code) DO NOTHING;

  SELECT id INTO r_super FROM public.enterprise_roles WHERE enterprise_id = p_enterprise_id AND code = 'super_admin';
  SELECT id INTO r_admin FROM public.enterprise_roles WHERE enterprise_id = p_enterprise_id AND code = 'admin';
  SELECT id INTO r_operator FROM public.enterprise_roles WHERE enterprise_id = p_enterprise_id AND code = 'operator';
  SELECT id INTO r_hm FROM public.enterprise_roles WHERE enterprise_id = p_enterprise_id AND code = 'health_manager';
  SELECT id INTO r_finance FROM public.enterprise_roles WHERE enterprise_id = p_enterprise_id AND code = 'finance';

  -- 超级管理员：全部权限
  INSERT INTO public.enterprise_role_permissions (role_id, permission_code)
  SELECT r_super, code FROM public.permission_definitions
  ON CONFLICT DO NOTHING;

  -- 管理员：除「角色权限」外全部
  INSERT INTO public.enterprise_role_permissions (role_id, permission_code)
  SELECT r_admin, code FROM public.permission_definitions WHERE code <> 'enterprise_roles'
  ON CONFLICT DO NOTHING;

  -- 运营
  INSERT INTO public.enterprise_role_permissions (role_id, permission_code)
  SELECT r_operator, code FROM public.permission_definitions
  WHERE code IN ('dashboard','stats','clients','surveys','content','products','orders','reputation','decorate','live','invite','logs')
  ON CONFLICT DO NOTHING;

  -- 健康管理师
  INSERT INTO public.enterprise_role_permissions (role_id, permission_code)
  SELECT r_hm, code FROM public.permission_definitions
  WHERE code IN ('dashboard','clients','weighing','health_agents','knowledge','qa','surveys','conversations','diet_map','health_insights')
  ON CONFLICT DO NOTHING;

  -- 财务
  INSERT INTO public.enterprise_role_permissions (role_id, permission_code)
  SELECT r_finance, code FROM public.permission_definitions
  WHERE code IN ('stats','orders','logs','data_export')
  ON CONFLICT DO NOTHING;
END;
$function$;

REVOKE ALL ON FUNCTION public.seed_enterprise_default_roles_fn(uuid) FROM PUBLIC;

-- 3) 新企业插入时自动播种角色
CREATE OR REPLACE FUNCTION public.trg_enterprise_seed_roles_fn()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  PERFORM public.seed_enterprise_default_roles_fn(NEW.id);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_enterprise_seed_roles ON public.enterprises;
CREATE TRIGGER trg_enterprise_seed_roles
  AFTER INSERT ON public.enterprises
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_enterprise_seed_roles_fn();

-- 4) 现有企业回填：播种角色 + 按旧 sub_role 映射成员角色
DO $function$
DECLARE
  r RECORD;
BEGIN
  FOR r IN SELECT id FROM public.enterprises LOOP
    PERFORM public.seed_enterprise_default_roles_fn(r.id);
  END LOOP;

  -- owner -> 超级管理员
  UPDATE public.profiles p
     SET enterprise_role_id = er.id
    FROM public.enterprises e
    JOIN public.enterprise_roles er ON er.enterprise_id = e.id AND er.code = 'super_admin'
   WHERE p.id = e.owner_profile_id
     AND p.enterprise_role_id IS NULL;

  -- 旧 sub_role 映射到新角色
  UPDATE public.profiles p
     SET enterprise_role_id = er.id
    FROM public.enterprise_roles er
   WHERE p.enterprise_id = er.enterprise_id
     AND p.enterprise_role_id IS NULL
     AND (
       (p.sub_role = 'admin' AND er.code = 'admin')
       OR (p.sub_role = 'health_manager' AND er.code = 'health_manager')
       OR (p.sub_role = 'service' AND er.code = 'operator')
       OR (p.sub_role = 'analyst' AND er.code = 'finance')
     );

  -- 剩余无角色员工 -> 健康管理师
  UPDATE public.profiles p
     SET enterprise_role_id = er.id
    FROM public.enterprise_roles er
   WHERE p.enterprise_id = er.enterprise_id
     AND p.role = 'manager'
     AND p.enterprise_role_id IS NULL
     AND er.code = 'health_manager';
END;
$function$;