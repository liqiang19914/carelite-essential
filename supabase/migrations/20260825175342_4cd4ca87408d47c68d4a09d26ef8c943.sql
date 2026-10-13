INSERT INTO public.manager_public_qa_sessions
  (manager_id, visitor_token, visitor_user_id, entry_source, context_type, context_id, list_visible, first_message, message_count, last_active_at)
VALUES
  ('31685996-3218-4b31-bd05-7128beee7426', 'ent-verify-A-20260825', 'ead98a94-f781-4671-895b-5261e889acb3', 'manager_chat', NULL, NULL, TRUE, '企业端夹具A', 2, now()),
  ('31685996-3218-4b31-bd05-7128beee7426', 'ent-verify-B-20260825', 'ead98a94-f781-4671-895b-5261e889acb3', 'composition', 'composition', NULL, FALSE, '企业端夹具B', 1, now() - interval '1 minute');

INSERT INTO public.manager_public_qa_messages (session_id, role, content)
SELECT id, 'user', '企业端夹具问题'
FROM public.manager_public_qa_sessions WHERE visitor_token = 'ent-verify-A-20260825';

INSERT INTO public.manager_public_qa_messages (session_id, role, content)
SELECT id, 'assistant', '企业端夹具回答'
FROM public.manager_public_qa_sessions WHERE visitor_token = 'ent-verify-A-20260825';