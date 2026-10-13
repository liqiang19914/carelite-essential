-- 商户可见性改由「谁产出的」决定：
-- ① 数据带着我（或我企业员工）的商户章 —— 是在我的应用里测出来的，我看得到；
--    不再要求客户额外点过授权（耀美就是这么被挡在外面的：数据在它的小程序里测的，
--    但客户从没给它单独授权，于是产出方看不到、别家商户反而看得到）。
-- ② 还没确定归属的历史数据 —— 沿用原来的授权闸门，不放宽也不收紧。
-- 客户关掉体征共享时两条路径都看不到，这条承诺不变。
DROP POLICY IF EXISTS "Managers view authorized body compositions" ON public.body_compositions;
CREATE POLICY "Managers view authorized body compositions"
ON public.body_compositions FOR SELECT
USING (
  (public.oem_stamp_in_my_scope(oem_manager_id) AND public.record_vitals_shared(record_id))
  OR (oem_manager_id IS NULL AND public.can_current_manager_view_body_composition(record_id))
);

DROP POLICY IF EXISTS "Enterprise admin views member body compositions" ON public.body_compositions;
CREATE POLICY "Enterprise admin views member body compositions"
ON public.body_compositions FOR SELECT
USING (
  oem_manager_id IS NULL
  AND public.can_current_enterprise_admin_view_body_composition(record_id)
);