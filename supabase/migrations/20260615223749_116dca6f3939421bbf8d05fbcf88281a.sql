-- 清理旧 drill（伪造 IP），插入真实出口 IP 哈希 9bd884dfcf0dccb53910ee60250ed15b 的 10 条 user 消息
DELETE FROM public.manager_public_qa_sessions
WHERE visitor_token = 'pqa_rate_limit_drill';

DO $$
DECLARE
  v_session_id UUID;
  i INT;
BEGIN
  INSERT INTO public.manager_public_qa_sessions
    (manager_id, visitor_token, visitor_ip_hash, first_message, message_count, last_active_at)
  VALUES
    ('a6f5c22f-33ec-411f-ad26-3777ebbb534e',
     'pqa_rate_limit_drill',
     '9bd884dfcf0dccb53910ee60250ed15b',
     '演练（真实出口）',
     10,
     NOW())
  RETURNING id INTO v_session_id;

  FOR i IN 1..10 LOOP
    INSERT INTO public.manager_public_qa_messages (session_id, role, content, created_at)
    VALUES (v_session_id, 'user', '演练 ' || i, NOW() - (interval '1 second' * i));
  END LOOP;
END $$;