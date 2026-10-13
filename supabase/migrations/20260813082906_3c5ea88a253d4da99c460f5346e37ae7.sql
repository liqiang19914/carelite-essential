-- health_records：加一条「按商户归属」的放行策略（不要求 record_authorizations）
CREATE POLICY "Managers can view client records via relation" ON public.health_records
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM client_relations cr
      WHERE cr.client_id = health_records.user_id
        AND cr.manager_id = uid()
        AND cr.status = 'active'
    )
    AND can_manager_view_client_category(health_records.user_id, 'share_records')
  );