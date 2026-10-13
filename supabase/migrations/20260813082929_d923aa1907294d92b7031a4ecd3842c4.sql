-- vital_signs：加一条「按商户归属」的放行策略
CREATE POLICY "Managers can view client vitals via relation" ON public.vital_signs
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM health_records hr
      JOIN client_relations cr ON cr.client_id = hr.user_id
      WHERE hr.id = vital_signs.record_id
        AND cr.manager_id = uid()
        AND cr.status = 'active'
    )
    AND can_manager_view_client_category(
      (SELECT hr.user_id FROM health_records hr WHERE hr.id = vital_signs.record_id),
      'share_vitals'
    )
  );