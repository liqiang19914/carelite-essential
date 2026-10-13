DROP POLICY IF EXISTS "Managers can view client conversations when granted" ON public.conversations;
CREATE POLICY "Managers can view client conversations when granted"
  ON public.conversations FOR SELECT
  USING (
    public.can_manager_view_client_data(user_id, 'view_conversations')
    AND public.oem_stamp_in_my_scope(owner_manager_id)
  );

DROP POLICY IF EXISTS "Managers can view client messages when granted" ON public.messages;
CREATE POLICY "Managers can view client messages when granted"
  ON public.messages FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.conversations c
      WHERE c.id = messages.conversation_id
        AND public.can_manager_view_client_data(c.user_id, 'view_conversations')
        AND public.oem_stamp_in_my_scope(c.owner_manager_id)
    )
  );