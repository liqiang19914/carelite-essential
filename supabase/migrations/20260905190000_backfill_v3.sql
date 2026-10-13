-- 回溯补写 v3：role 用 text 类型
INSERT INTO public.conversations
  (id, user_id, agent_id, title, owner_manager_id, updated_at, created_at)
SELECT
  s.id,
  s.visitor_user_id,
  NULL,
  CASE
    WHEN s.entry_source = 'composition' THEN '[体成分解读] ' || LEFT(COALESCE(s.first_message, ''), 45)
    WHEN s.entry_source = 'shop_service' THEN '[服务咨询] ' || LEFT(COALESCE(s.first_message, ''), 45)
    ELSE '[健管师对话] ' || LEFT(COALESCE(s.first_message, ''), 45)
  END::varchar(200),
  s.manager_id,
  s.last_active_at,
  s.created_at
FROM public.manager_public_qa_sessions s
WHERE s.visitor_user_id IS NOT NULL
  AND EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = s.visitor_user_id)
  AND NOT EXISTS (SELECT 1 FROM public.conversations c WHERE c.id = s.id);

-- 回溯 messages
INSERT INTO public.messages
  (conversation_id, role, content, created_at)
SELECT qm.session_id, qm.role::text, qm.content, qm.created_at
FROM public.manager_public_qa_messages qm
WHERE EXISTS (
  SELECT 1 FROM public.conversations c WHERE c.id = qm.session_id
)
AND NOT EXISTS (
  SELECT 1 FROM public.messages m
  WHERE m.conversation_id = qm.session_id AND m.content = qm.content
);
