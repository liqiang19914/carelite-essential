-- 检查并补齐这两个函数的调用权限。
-- manager_weighing_people 被 CREATE OR REPLACE 后，按 Postgres 规则若函数此前从未 GRANT 过
-- 则保有默认 PUBLIC 执行权；但为确保两类登录用户都能调用，显式补上。
GRANT EXECUTE ON FUNCTION public.manager_weighing_people(text, date, date, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_weighing_overview() TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_measure_ticket(uuid, text, uuid) TO authenticated;