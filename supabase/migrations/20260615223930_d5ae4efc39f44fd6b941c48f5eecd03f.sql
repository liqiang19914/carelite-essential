-- 验收：token-based daily limit。预置 80 条 user 消息到一个 session
DELETE FROM public.manager_public_qa_sessions
WHERE visitor_token = 'pqa_token_drill';

DO $$
DECLARE
  v_session_id UUID;
  i INT;
BEGIN
  INSERT INTO public.manager_public_qa_sessions
    (manager_id, visitor_token, visitor_ip_hash, first_message, message_count, last_active_at)
  VALUES
    ('a6f5c22f-33ec-411f-ad26-3777ebbb534e',
     'pqa_token_drill',
     'unused_ip_hash',
     '演练 token 限流',
     80,
     NOW())
  RETURNING id INTO v_session_id;

  FOR i IN 1..80 LOOP
    INSERT INTO public.manager_public_qa_messages (session_id, role, content, created_at)
    VALUES (v_session_id, 'user', '演练 ' || i, NOW() - (interval '1 minute' * (i / 5.0)));
  END LOOP;
END $$;