-- feature 289 补充：存量无角色员工按旧 sub_role 幂等回填企业角色
--（系统预置健管师等后建员工没有 enterprise_role_id，员工列表角色显示与权限判定都缺）

UPDATE public.profiles p
   SET enterprise_role_id = er.id
  FROM public.enterprise_roles er
 WHERE p.enterprise_id = er.enterprise_id
   AND p.role = 'manager'
   AND p.enterprise_role_id IS NULL
   AND (
     (p.sub_role = 'admin' AND er.code = 'admin')
     OR (p.sub_role = 'health_manager' AND er.code = 'health_manager')
     OR (p.sub_role = 'service' AND er.code = 'operator')
     OR (p.sub_role = 'analyst' AND er.code = 'finance')
   );

UPDATE public.profiles p
   SET enterprise_role_id = er.id
  FROM public.enterprise_roles er
 WHERE p.enterprise_id = er.enterprise_id
   AND p.role = 'manager'
   AND p.enterprise_role_id IS NULL
   AND er.code = 'health_manager';