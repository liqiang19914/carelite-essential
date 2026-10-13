-- 限流验收：预先插入 10 条 user 消息到一个"演练"会话，IP 哈希 = a802c8f60a253488a49930ec52955582
-- 然后用相同 x-forwarded-for 调 EF，第 11 条应返回 429

DO $$
DECLARE
  v_session_id UUID;
  i INT;
BEGIN
  -- 清理上次同名 token 的演练数据
  DELETE FROM public.manager_public_qa_sessions
  WHERE manager_id = 'a6f5c22f-33ec-411f-ad26-3777ebbb534e'
    AND visitor_token = 'pqa_rate_limit_drill';

  INSERT INTO public.manager_public_qa_sessions
    (manager_id, visitor_token, visitor_ip_hash, first_message, message_count, last_active_at)
  VALUES
    ('a6f5c22f-33ec-411f-ad26-3777ebbb534e',
     'pqa_rate_limit_drill',
     'a802c8f60a253488a49930ec52955582',
     '演练',
     10,
     NOW())
  RETURNING id INTO v_session_id;

  FOR i IN 1..10 LOOP
    INSERT INTO public.manager_public_qa_messages (session_id, role, content, created_at)
    VALUES (v_session_id, 'user', '演练 ' || i, NOW() - (interval '1 second' * i));
  END LOOP;
END $$;