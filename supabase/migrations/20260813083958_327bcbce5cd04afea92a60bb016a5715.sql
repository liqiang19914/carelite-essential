-- health_insights：商户可看已授权客户的洞察（平台授予 + 商户开启）
CREATE POLICY "Managers can view client insights when granted" ON public.health_insights
  FOR SELECT USING (
    can_manager_view_client_data(user_id, 'view_health_insights')
  );

-- conversations：商户可看已授权客户的对话（平台授予 + 商户开启）
CREATE POLICY "Managers can view client conversations when granted" ON public.conversations
  FOR SELECT USING (
    can_manager_view_client_data(user_id, 'view_conversations')
  );

-- messages：商户可看已授权客户对话下的消息
CREATE POLICY "Managers can view client messages when granted" ON public.messages
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM conversations c
      WHERE c.id = messages.conversation_id
        AND can_manager_view_client_data(c.user_id, 'view_conversations')
    )
  );