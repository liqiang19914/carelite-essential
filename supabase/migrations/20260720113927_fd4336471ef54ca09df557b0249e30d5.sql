-- health_records:把原本的 owner OR manager 组合 policy 拆成两条清晰的 SELECT policy。
-- owner 分支永不受隐私阀门影响(用户自己看自己的档案不需要 gate)。
-- manager 分支加 share_records 阀门:客户关掉「健康档案可见」→ 管理师即使有 record_authorization 也读不到。
-- admin 保持通过独立的 admin_select_all_health_records policy 通行(超管绕过)。
DROP POLICY IF EXISTS "Managers can view authorized health records" ON public.health_records;

CREATE POLICY "Owners can view own health records"
  ON public.health_records
  FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Managers can view authorized health records"
  ON public.health_records
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.record_authorizations ra
      WHERE ra.record_id = health_records.id
        AND ra.manager_id = auth.uid()
        AND ra.is_active = true
    )
    AND public.can_manager_view_client_category(health_records.user_id, 'share_records')
  );

-- vital_signs:原本没有 manager select policy(等于历史上管理师完全读不到客户的体征打卡),
-- 补一条 manager policy —— 走 record_authorizations 授权 + share_vitals 阀门。
-- owner 已有独立 policy,admin 已有独立 policy,都保持不变。
CREATE POLICY "Managers can view authorized vital signs"
  ON public.vital_signs
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.record_authorizations ra
      JOIN public.health_records hr ON hr.id = ra.record_id
      WHERE ra.record_id = vital_signs.record_id
        AND ra.manager_id = auth.uid()
        AND ra.is_active = true
        AND public.can_manager_view_client_category(hr.user_id, 'share_vitals')
    )
  );